# SBN Completed Inspections → Snowflake

Runs WKS's existing **`SBN_Completed_Inspections_Daily.ipynb`** and **`sbn_common.py`** on Snowflake, on a daily schedule, writing to the same dataset it writes in Domo today: **`SBN | Completed Inspections | RAW`**.

This is the **lift-and-shift** version: the Domo code with the fewest changes needed to run in Snowflake. It installs into the schema `WKS_POC.SBN_LIFT_SHIFT`.

## Run in this order

| Step | File | What it does |
|---|---|---|
| 1 | `01_setup.sql` | Warehouse, compute pool, database/schema, SBN secret, network rule + external access integration, two stages |
| 1b *(optional)* | `01b_create_table.sql` | Creates the target table up front, with the exact types the notebook writes. Only needed to load history another way first (e.g. from a CSV); includes a load template. Otherwise the one-time load in step 3 creates the table. |
| 2 | `02_upload_and_create_code_bundle.sql` | Pulls the code from GitHub into Snowflake (Git repository `WKS_REPO`), copies it to the `BUNDLE_SRC` stage, and packages it as the Code Bundle `SBN_DAILY`. No manual file upload. |
| 3 | `03_initial_load.sql` | One-time history load, then the first daily run |
| 4 | `04_schedule_and_monitor.sql` | Daily 5:00 AM Pacific schedule, plus monitoring queries |

Run each script in a Snowsight SQL worksheet as ACCOUNTADMIN. Before step 1:
- put the SBN username and password (the values from `sbn.env`) into `01_setup.sql`;
- create the GitHub API integration once per account (step 2 needs it; the repo is public, so no GitHub credentials are needed):
  ```sql
  CREATE API INTEGRATION IF NOT EXISTS GIT_HUB_INTEGRATION
    API_PROVIDER = git_https_api
    API_ALLOWED_PREFIXES = ('https://github.com/')
    ENABLED = TRUE;
  ```

Each `EXECUTE CODE BUNDLE` takes about 2 minutes, mostly container start-up rather than the code. `03_initial_load.sql` explains the breakdown.

## Folder layout

```
01_setup.sql
01b_create_table.sql
02_upload_and_create_code_bundle.sql
03_initial_load.sql
04_schedule_and_monitor.sql
code_bundle/                              ← these 6 files are copied from GitHub to the BUNDLE_SRC stage by step 2
  SBN_Completed_Inspections_Daily.ipynb   the Domo notebook (8 lines added, nothing else changed)
  sbn_common.py                           unchanged
  domojupyter.py                          stand-in for Domo's domojupyter library
  code_bundle.yml                         compute, packages, secret, network access, working folder
  requirements.txt                        python-dotenv
  backfill_seed.py                        optional one-time history load
```
The files in `code_bundle/` keep their exact names: the notebook imports `sbn_common` and `domojupyter` by name, and Snowflake requires the name `code_bundle.yml`.

## What changed from the Domo version

| File | Change |
|---|---|
| `sbn_common.py` | **None.** Identical to the Domo version. |
| `SBN_Completed_Inspections_Daily.ipynb` | **8 lines added** to the first code cell (shown below). No existing line removed or edited; the other 6 cells are identical. |
| `domojupyter.py` | **New.** Snowflake stand-in for Domo's `domojupyter` module, so `import domojupyter as domo` and the notebook's two calls, `domo.read_dataframe(...)` and `domo.write_dataframe(..., update_method="REPLACE")`, work unchanged. Each Domo dataset becomes a table with the same name and column names, e.g. `WKS_POC.SBN_LIFT_SHIFT."SBN \| Completed Inspections \| RAW"`. |
| `code_bundle.yml`, `requirements.txt` | **New.** They replace the Domo Workspace settings and `sbn.env`. |

The added block, right after `load_dotenv(ENV_FILE)`:
```python
# --- Snowflake port: no sbn.env in Snowflake; load the same two values from a Snowflake secret ---
from snowflake.snowpark.secrets import get_username_password
_sbn = get_username_password(os.environ["SBN_SECRET_PATH"])  # set in code_bundle.yml
os.environ.setdefault("SBN_USERNAME", _sbn.username)
os.environ.setdefault("SBN_PASSWORD", _sbn.password)
os.chdir("/mnt/sbn_state")  # Code Bundle folder is read-only; work from a persistent stage so ./state survives runs
# --- end Snowflake port ---
```
- **Credentials:** `sbn.env` becomes a Snowflake secret. The notebook still reads `SBN_USERNAME` and `SBN_PASSWORD` with `os.getenv`, exactly as before.
- **`os.chdir`:** the notebook's `./state/last_row_count.txt` (used by its "0 rows read" safety check) lives on a stage, so it's kept between runs, like the Domo Workspace folder.

The 8th added line is optional and commented out. It sits right under the existing `DATASET_NAME` line in the same cell:
```python
DATASET_NAME = "SBN | Completed Inspections | RAW"
# DATASET_NAME = "SBN_COMPLETED_INSPECTIONS_RAW"  # Snowflake-friendly name: comment out the line above and uncomment this one; also change the table name in backfill_seed.py, 01b_create_table.sql, 03_initial_load.sql and 04_schedule_and_monitor.sql
```
The Domo name works as is, but in Snowflake it has to be written in double quotes in every query. To switch to the plain name:
1. Swap which of the two lines is commented out, in the notebook and in `backfill_seed.py`.
2. Update the table name in `01b_create_table.sql`, `03_initial_load.sql` and `04_schedule_and_monitor.sql`.
3. Push to GitHub, re-run the fetch / copy / add-version commands (see Monitoring and changes).
4. Run the one-time load again, since the new name starts as an empty table.

## What `01_setup.sql` creates

| Object | Level | Purpose |
|---|---|---|
| `INGESTION_WH` | Account | Gen2 XS warehouse, 30s auto-suspend. Runs the SQL behind `read_dataframe` / `write_dataframe`. |
| `INGESTION_POOL` | Account | Compute pool, 1 node of `CPU_X64_XS` (the smallest), 5 min auto-suspend. The notebook's Python runs here. |
| `SBN_API_EAI` | Account | **External access integration.** Attaches the network rule (and the secret) to the notebook. Without it, Snowflake blocks the API call. |
| `WKS_POC.SBN_LIFT_SHIFT` | Database / schema | Holds everything below plus the dataset table. |
| `SBN_CREDENTIALS` | Schema | Secret holding the SBN username and password (replaces `sbn.env`). |
| `SBN_API_NETWORK_RULE` | Schema | **Network rule.** Allows outbound traffic to `wks.simplebutneeded.net:443` only. |
| `BUNDLE_SRC` | Schema | Stage the `code_bundle/` files are copied to from GitHub (step 2). |
| `NOTEBOOK_STATE` | Schema | Stage mounted as the notebook's working folder (`/mnt/sbn_state`). |

Later steps add the Code Bundle `SBN_DAILY`, the table `"SBN | Completed Inspections | RAW"` (created by the first load), and the task `SBN_DAILY_TASK`.

## Using a different database or schema
Every script starts with `USE DATABASE WKS_POC; USE SCHEMA SBN_LIFT_SHIFT;` and refers to objects by short name. To use other names:
1. Change those two lines at the top of each numbered script, plus `CREATE DATABASE` / `CREATE SCHEMA` in `01_setup.sql`.
2. In `code_bundle/code_bundle.yml`, change the **5 values marked `<<<`**. Code Bundle settings need full names.
3. In `02_upload_and_create_code_bundle.sql`, the `COPY FILES` path points at `sbn_ingest_lift_shift/code_bundle/` in the GitHub repo; change it if you move the folder.

Nothing in the notebook or `sbn_common.py` needs to change.

## Monitoring and changes
- **Run history:** Catalog → WKS_POC → SBN_LIFT_SHIFT → Code Bundles → `SBN_DAILY` → Run history (each run shows the notebook output). Or use the queries in `04_schedule_and_monitor.sql`.
- **Changing code:** push the change to GitHub, then run `ALTER GIT REPOSITORY WKS_REPO FETCH;`, `COPY FILES INTO @BUNDLE_SRC FROM @WKS_REPO/branches/main/sbn_ingest_lift_shift/code_bundle/;` and `ALTER CODE BUNDLE SBN_DAILY ADD VERSION FROM @BUNDLE_SRC;` (also at the bottom of step 2). Bundles are versioned snapshots, so the schedule keeps using the old version until you add a new one.
- **Rotating the SBN password:** `ALTER SECRET SBN_CREDENTIALS SET PASSWORD = '...';`.

## Things to know
- **Runs as your user's default role.** Code Bundles execute with the calling user's **default role** (plus secondary roles), not the role selected in the worksheet. These steps assume that user's default role is ACCOUNTADMIN. For a dedicated role, grant it:
  - `READ` on the secret
  - `USAGE` on the integration, compute pool, database and schema
  - `USAGE` and `MONITOR` on the warehouse
  - `USAGE` on the Code Bundle `SBN_DAILY`
  - `READ`/`WRITE` on both stages
  - `CREATE TABLE` on the schema (plus `OWNERSHIP` of the table, since each run re-creates it)

  Then make it that user's default role. This list comes from the `EXECUTE CODE BUNDLE` docs; it hasn't been tested end to end with a non-ACCOUNTADMIN user.
- **Packages:** `pandas`, `requests` and Snowpark come with Snowflake's notebook runtime. Only `python-dotenv` is installed, from Snowflake's PyPI repository.
- **IP allowlisting:** if SBN restricts API access by IP address, Snowflake's outbound IPs aren't fixed by default. Check with SBN.
- **Timestamps** are stored as UTC (`sbn_common.cast_schema` converts them), the same as in Domo.
- **Cost:** the warehouse and compute pool both auto-suspend. A daily run is a few minutes of one XS compute pool node, plus seconds of XS warehouse.

## Known limitations carried over from the Domo version
These work exactly as they do in Domo today.
- **Every run re-creates the table.** The write is `REPLACE`, so after each run, anything added on the table is gone: grants to other roles, row access policies, comments. Dynamic tables built on it fail to refresh. (Tested in Snowflake.)
- **Reopened inspections stay "completed".** An inspection that is completed and later reopened in SBN is logged as a warning, but its row stays in the table as completed.
- **Paging could stop early.** If the SBN API returns fewer rows per page than requested (500), `sbn_common.paginate` stops after the first page. For completed jobs the count check catches this and aborts the run. For the modified-jobs pull (edits and reopened jobs) there's no count check, so rows could be silently missed.
