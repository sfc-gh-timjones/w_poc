# SBN Completed Inspections → Snowflake (Code Bundle on a warehouse, raw VARIANT)

Loads SBN inspection data into Snowflake every day **as raw JSON, in VARIANT tables**, using a **Code Bundle that runs on a warehouse**. It installs into the schema `WKS_POC.SBN_INGEST`.

**This is the version to implement.** It's completely separate from the lift-and-shift (`SBN_LIFT_SHIFT`): its own schema, secret, network rule (`SBN_INGEST_NETWORK_RULE`) and external access integration (`SBN_INGEST_EAI`). The only shared object is the warehouse `INGESTION_WH`. Both can run side by side.

The flattening, joins and the Risk | Compliance Report are in [`../TRANSFORMATIONS/`](../TRANSFORMATIONS/). They're dynamic tables that read these raw tables; set them up after this.

This is the Code Bundle option alongside [`sbn_ingest_sproc_warehouse`](../sbn_ingest_sproc_warehouse/), the stored-procedure option. **Both land exactly the same data the same way**, using the same Python file, `sbn_refresh.py`. They differ only in how it's run:

| | sbn_ingest_sproc_warehouse | sbn_ingest_codebundle_warehouse (this) |
|---|---|---|
| Runs as | Stored procedure: `CALL SBN_REFRESH()` | Code Bundle: `EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py'` |
| Runs on | Warehouse | Warehouse (`compute_type: warehouse`; Public Preview) |
| Code | `sbn_refresh.py`, read from GitHub by `IMPORTS` | `sbn_refresh.py` + a small entrypoint, `sbn_daily.py`, copied from GitHub to a stage |
| Configuration | In the `CREATE PROCEDURE` statement | In `code_bundle.yml` |
| Run history | Query history / task history | Code Bundle run history (Snowsight shows each run's output) |
| Output | `SBN_JOBS_RAW`, `SBN_USERS_RAW`, `SBN_CHECKLISTS_RAW` (raw JSON) | Same |

Compared with [`sbn_ingest_notebook_compute_pool`](../sbn_ingest_notebook_compute_pool/), which runs the notebook on a **compute pool** and writes flattened, structured columns, this version runs on the warehouse and lands the raw JSON. Flattening is done downstream.

## How it works
```
SBN API ──EXECUTE CODE BUNDLE──▶  SBN_JOBS_RAW   (every job, any status, one row per id)
          (on INGESTION_WH)       SBN_USERS_RAW      (users)
                                  SBN_CHECKLISTS_RAW (checklists)
                                  each: ID, PAYLOAD (VARIANT = the API's JSON), LOADED_AT
```

`sbn_daily.py` reads the arguments and the secret, then calls `sbn_refresh.run()`. That:
- pulls users and checklists in full;
- pulls completed jobs in the window, month by month;
- pulls any job modified in the last 30 days, which brings in edits and reopened jobs.

Every pull is checked against the API's own count; a short pull fails the run and writes nothing. Everything is then applied in one transaction:
- the user and checklist tables are replaced;
- jobs are `MERGE`d on `id`: new ids are inserted, and an existing id is updated only if the new version is at least as new **and** its JSON differs.

Nothing is deleted. A reopened inspection keeps its new `job_status` in `SBN_JOBS_RAW`. Downstream, filter on `PAYLOAD:job_status = 'completed'` for completed inspections; `../TRANSFORMATIONS/` does this, so reopened inspections drop out of the report.

## Run in this order
| Step | File | What it does |
|---|---|---|
| 1 | `01_setup.sql` | Warehouse, database/schema, SBN secret, network rule, external access integration `SBN_INGEST_EAI`, code stage |
| 2 | `02_tables.sql` | The three raw VARIANT tables (with change tracking, for the dynamic tables in `../TRANSFORMATIONS/`), plus the timestamp helper the `MERGE` uses |
| 3 | `03_upload_and_create_code_bundle.sql` | Copies `codebundle/` from GitHub to the stage and creates the Code Bundle `SBN_DAILY` |
| 4 | `04_initial_load.sql` | API check, history load (`--days-back 560`), then the first daily run |
| 5 | `05_schedule_and_monitor.sql` | Daily 5:00 AM Pacific task, plus monitoring queries |

Run each script in a Snowsight SQL worksheet as ACCOUNTADMIN. Before step 1:
- put the SBN username and password (the values from `sbn.env`) into `01_setup.sql`;
- create the GitHub API integration once per account (step 3 needs it):
  ```sql
  CREATE API INTEGRATION IF NOT EXISTS GIT_HUB_INTEGRATION
    API_PROVIDER = git_https_api
    API_ALLOWED_PREFIXES = ('https://github.com/')
    ENABLED = TRUE;
  ```
  Step 3 needs the GitHub repo to be public. For a private repo, add a GitHub token secret and `GIT_CREDENTIALS` to `CREATE GIT REPOSITORY`, or upload the 3 files in `codebundle/` to the `BUNDLE_SRC` stage by hand.

**The warehouse is chosen when you run it.** A warehouse Code Bundle runs on the warehouse that's active at `EXECUTE` time. The scripts set `USE WAREHOUSE INGESTION_WH`, and the task uses `WAREHOUSE = INGESTION_WH`.

## Folder layout
```
01_setup.sql
02_tables.sql
03_upload_and_create_code_bundle.sql
04_initial_load.sql
05_schedule_and_monitor.sql
codebundle/
  code_bundle.yml    compute_type: warehouse, secret, network access, env vars
  sbn_daily.py       entrypoint: arguments + secret, then calls sbn_refresh.run()
  sbn_refresh.py     the API and load logic (identical to sbn_ingest_sproc_warehouse's)
```

## Run time: warehouse vs compute pool (measured 2026-11-13, Code Bundle run history)
**Test 1: the same bundle, same code, both calling the real SBN API** and stopping at the same point (the test credentials are rejected at login). So the difference is purely start-up:

| Where it runs | Runs | Time each |
|---|---|---|
| Warehouse (`compute_type: warehouse`) | 4 | **5–10 s** |
| Compute pool (same bundle, via `WITH SPECIFICATION`) | 3 | **96–114 s** |

**Test 2: a full daily load against the mock SBN API** (compute pool only; a warehouse can't reach the mock, see below):

| Run | Time |
|---|---|
| sbn_ingest_notebook_compute_pool daily (notebook) | 106 s |
| This version's load code, daily | 105 s |

Both match the compute pool's start-up time alone, so the API calls and load for a daily run take only seconds. On the warehouse, a daily run should therefore take roughly **15–20 s** instead of ~105 s. That's an estimate: warehouse start-up plus the work, not a measured full run, because the warehouse can't reach the mock.

## API check (`--mode check`, step 4)
Same read-only check as sbn_ingest_sproc_warehouse, run once before the history load. The result is in the run's output (Code Bundles → `SBN_DAILY` → Run history).

| Check | Result | Action |
|---|---|---|
| 1. Page size | `OK` or `API CAPS PAGES AT N` | None; paging handles either |
| 2. `/count/` with `modified__gte` | `OK (...)` | None |
| 2. `/count/` with `modified__gte` | the run **fails** with `... FAILED` | **Required before scheduling:** tell your Snowflake contact; the modified-jobs count check has to change |
| 3. Reopened jobs | `consistent with reopening updating the modified date` | None |
| 3. Reopened jobs | `SOME were NOT modified after completion` | **Confirm with SBN** how reopening sets the modified date; loading still works |
| 3. Reopened jobs | `none found` | Optional: reopen one test inspection, run the daily, check its `job_status` in `SBN_JOBS_RAW` |

## Things to know
- **Reading the secret depends on where the bundle runs.** Found in testing, 2026-11-13:
  - on a **warehouse**, the bare name `SBN_CREDENTIALS` works;
  - on a **compute pool**, the lowercase path `wks_poc/sbn_ingest/sbn_credentials` works;
  - the full dotted name shown in the docs failed on both.

  `sbn_daily.py` tries all three, so the same files run on either.
- **Running it on a compute pool instead** needs no file changes, only an inline override (expect ~100 s more per run, mostly container start-up):
  ```sql
  EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py'
  WITH SPECIFICATION $$
  bundle:
    type: custom
    compute_type: compute_pool
    language: python
    compute_options:
      compute_pool: <your_compute_pool>
      query_warehouse: INGESTION_WH
      runtime_version: 'V2.9-CPU-PY3.12'
    external_access_integrations:
      - SBN_INGEST_EAI
    secrets:
      - WKS_POC.SBN_INGEST.SBN_CREDENTIALS
    env_vars:
      - SBN_SECRET: 'WKS_POC.SBN_INGEST.SBN_CREDENTIALS'
      - TARGET_DATABASE: 'WKS_POC'
      - TARGET_SCHEMA: 'SBN_INGEST'
  $$;
  ```
- **Warehouse Code Bundles are Public Preview** (compute pool Code Bundles are generally available).
- **Runs as your user's default role.** Code Bundles execute with the calling user's **default role** (plus secondary roles), not the worksheet's role. These steps assume it's ACCOUNTADMIN.
- **IP allowlisting:** if SBN restricts API access by IP address, Snowflake's outbound IPs aren't fixed by default. Check with SBN.
- **Cost:** only the XS warehouse, for the length of each run.

## Testing done
- **Warehouse:** the bundle ran from the warehouse, read the secret, and reached the real `wks.simplebutneeded.net`, which answered HTTP 403 to the test credentials. That proves the secret, the integration and outbound access work.
- **Load logic:** `sbn_refresh.py` was tested end to end against a mock: the history load, a daily after simulated activity, and check mode. A flattened view over its raw tables showed 0 differences against an independent implementation.

**Not verified on the real API:** `/count/` accepting `modified__gte`; reopening updating the modified date; a full load with real data. Step 4's check covers the first two.

- **2026-11-15, in `SBN_INGEST`:** this exact bundle (same files) loaded the mock end to end: a history load, a simulated day, then a daily run. It ran on the compute pool via `WITH SPECIFICATION`, because a warehouse can't reach the mock. The raw tables then fed `../TRANSFORMATIONS/`, whose report matched the lift-and-shift report row for row (7,350 rows, 0 differences).
- **Warehouse compute against a real outside API** was proven separately with public test APIs using the same pattern (network rule + external access integration + secret). The real SBN API isn't called in testing.
