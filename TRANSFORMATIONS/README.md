# TRANSFORMATIONS — SBN raw JSON → Risk | Compliance Report (dynamic tables)

Turns the raw SBN JSON loaded by [`../sbn_ingest_codebundle_warehouse/`](../sbn_ingest_codebundle_warehouse/) into:
1. **`sbn_completed_inspections`**: the same data as the Domo dataset `SBN | Completed Inspections | RAW`;
2. **`risk_compliance_report`**: the same report as the Domo Magic ETL `Risk | Compliance Report | PROD` (dataflow 846).

It uses plain underscore column names throughout, and everything is a **dynamic table**. There are no tasks to schedule: Snowflake keeps each table up to date from its inputs.

Everything installs into the schema **`WKS_POC.TRANSFORMATIONS`**.

## How it flows
```
SBN_INGEST.SBN_JOBS_RAW    ─ sbn_jobs ─────────┐
SBN_INGEST.SBN_USERS_RAW       ─ sbn_users ────────┼─ sbn_completed_inspections ─ daily_form_completions ─ restaurant_form_days ─┐
SBN_INGEST.SBN_CHECKLISTS_RAW  ─ sbn_checklists ───┘                                                                            │
G_SHEET.SHEETS__LOCATION_MASTER ─ restaurant_locations ─┐                                                                  │
PUBLIC.WKS_FISCAL_CALENDAR_...  ─ compliance_calendar ──┴─ restaurant_days ───────────────────────────────────────────────┼─ restaurant_days_enriched ─ risk_compliance_report
WKS_PLUS.WKS_PLUS_PROGRESS_REPORT_RAW ─ safety_training_by_due_date ───────────────────────────────────────────────────────┘
```

| Dynamic table | Replaces (Domo) | What it holds |
|---|---|---|
| `sbn_jobs` | (the notebook's flattening) | Every SBN job, any status, JSON fields as columns, location split into levels 1–10, `location_code` from `[code]` |
| `sbn_users`, `sbn_checklists` | (the notebook's lookups) | User names, checklist names |
| `sbn_completed_inspections` | Dataset `SBN \| Completed Inspections \| RAW` | Completed inspections with user and checklist names |
| `restaurant_locations` | Locations MASTER + "Restaurant Only" | Open restaurants |
| `compliance_calendar` | Fiscal Calendar + "Create Compliance Proxy Date" | Each day and the compliance month it counts toward (the 19th rule) |
| `restaurant_days` | "Loc + Cal" | One row per restaurant per day |
| `daily_form_completions` | "Extract Location Code" + "Just necessary forms" | The 3 required forms, per location per day |
| `restaurant_form_days` | The location rule in "+ SBN Checklist" | Forms tied to a restaurant (Krispy Kreme / Wendy's by FranchisorUnit) |
| `safety_training_by_due_date` | WKS+ + "Safety" + "Group By" | Associates on time (≤ 3 days late) vs assigned |
| `restaurant_days_enriched` | "+ SBN Checklist" + "+ WKS+ Completion Data" | Restaurant-days with forms and training |
| `risk_compliance_report` | "Group By 1" + "Add Formula" | One row per restaurant per compliance month, with statuses, training rate, chargeback |

### Report columns (Domo name → new name)
| Domo | `risk_compliance_report` |
|---|---|
| Compliance Proxy Date | `compliance_month` |
| AdpLocationCode / LocationDesc | `adp_location_code` / `location_name` |
| District Leader & Area Filter / FranchisorAbbr | `district_area` / `franchisor_abbr` |
| Email / DL Email Address / RegionLeaderName / St | `store_email` / `district_leader_email` / `region_leader_name` / `state` |
| Monthly Employee Safety Behavior Observation Form Completion / Encoded | `employee_safety_observation_status` / `employee_safety_observation_completed` |
| Monthly Safety Committee Meeting Form Completion / Encoded | `safety_committee_meeting_status` / `safety_committee_meeting_completed` |
| Monthly Store Inspection Form Completion / Encoded | `store_inspection_status` / `store_inspection_completed` |
| WKS+ Completion / Encoded / Status | `safety_training_completion_rate` / `safety_training_passed` / `safety_training_status` |
| Chargeback | `chargeback_amount` |

## Run in this order
After the SBN ingest has loaded its raw tables, run each script in a Snowsight SQL worksheet as ACCOUNTADMIN:

| Step | File | What it does |
|---|---|---|
| 1 | `01_setup.sql` | Creates `TRANSFORMATIONS`, turns on change tracking on the 6 inputs, and checks they all exist |
| 2 | `02_sbn_dynamic_tables.sql` | Flattens the raw SBN JSON and joins it into `sbn_completed_inspections` |
| 3 | `03_compliance_dynamic_tables.sql` | The Risk \| Compliance Report |
| 4 | `04_validate.sql` | Read-only checks: refresh modes, latest refreshes, report sanity, unmatched locations |

## How fresh it is
- `risk_compliance_report` has **`TARGET_LAG = '1 hour'`**: it's never more than an hour behind its inputs. Every other table is `TARGET_LAG = DOWNSTREAM`, refreshed only when the report needs it.
- The SBN load runs at 5:00 AM Pacific, so the report is current by about 6:00 AM.
- To refresh right away (for example after a load): `ALTER DYNAMIC TABLE TRANSFORMATIONS.risk_compliance_report REFRESH;`
- Refreshes are **incremental**: only what changed is reprocessed. When nothing changed, the refresh is skipped and costs almost nothing.

## Differences from the Domo version (deliberate)
- **Reopened inspections drop out.** The raw table keeps each job's current status, and only `completed` jobs reach the report. So a reopened form no longer counts as completed. In Domo (and in the lift-and-shift), it stays counted as completed.
- **A missing user or checklist id gives NULL** instead of an empty string. An id that isn't in the list still shows as `user#<id>` / `checklist#<id>`.

## Same as Domo (confirmed or confirm with WKS)
- **Two SBN rows for the same restaurant and day are kept as separate rows** (confirmed with Grace, 2026-11-16). If the same restaurant appears under two different level-3 location names on the same day, both rows pass through to the report and training is counted twice in the monthly rate — matching the Magic ETL behavior.
- Months with no SBN data are charged for all 3 forms ($562.50) but not for training: no training data means no rate, and no rate means no charge.
- The report covers every month in the fiscal calendar, including future ones.
- "On time" counts associates, not episodes: an associate counts if *any* episode of the series was done on time.
- Hard-coded rules: the 19th cutoff, $187.50, the 90% threshold, the 3-day grace period, and the Krispy Kreme / Wendy's matching exception.
- **`completed_at::DATE` uses the UTC date — confirmed this matches Domo.** `sbn_common.py` (line 517) explicitly states "Domo stores DATETIME as UTC", and the Magic ETL export sets `typeOverride: DATE` on Completion Date, so Domo buckets by the UTC date too. The SQL replicates that behavior. **One question still worth asking Grace:** the SBN CSV export uses Pacific wall-clock time (UTC-7, per `sbn_common.py` line 526), so a form submitted at 10 PM Pacific on the 18th counts toward next month in both Domo and this report. Is that what she intends?

## Things to know
- **Inputs must be updated in place, not dropped and recreated.** A dynamic table stops refreshing if a table it reads is dropped and recreated. All 6 inputs are updated in place:
  - the SBN jobs table is MERGEd;
  - the SBN user and checklist tables get INSERT OVERWRITE;
  - the calendar was loaded once in the UI;
  - the Google Sheets Openflow connector **truncates and reloads** `SHEETS__LOCATION_MASTER` on each sync, per the Snowflake docs. That keeps the table, so the dynamic tables keep working. **Tested:** a truncate + reload of the location master refreshed fine, and the report was unchanged.
- **Full reloads make a refresh redo more work.** After a truncate + reload, every row looks new, even if nothing really changed. So everything built on that table is reprocessed. In testing, `restaurant_days` redid all 219,150 rows in about 3 seconds. The same happens with the SBN user and checklist tables, which are replaced in full every day: `sbn_completed_inspections` redoes all its rows (about 7 seconds for ~10,500). It's still correct, just not as cheap as a true incremental change.
- **Cost:** refreshes run on `INGESTION_WH` (XS). A daily change refreshes the whole chain in about 25 seconds in the demo.

## Tested (demo account, 2026-11-13)
The SBN data came from the mock SBN API, loaded by `../sbn_ingest_codebundle_warehouse/` into `SBN_INGEST`. The other 3 inputs were synthetic copies with WKS's exact table names, columns and types.

| Check | Result |
|---|---|
| All 12 dynamic tables created | 4 INCREMENTAL, 8 ADAPTIVE, none FULL |
| `sbn_completed_inspections` vs the lift-and-shift SBN table (same mock data) | 10,539 = 10,539 rows; 0 ids missing either way; 0 value differences |
| `risk_compliance_report` vs the lift-and-shift report (same inputs) | 7,350 = 7,350 rows; **0 differences across all 19 columns**; total chargeback $3,090,937.50 on both |
| Simulated day (+25 new, 20 edits, 3 reopened) → daily → refresh | Completed inspections 10,539 → 10,561 (+25 − 3 reopened); Nov 2026 forms completed 205 → 219; chargeback $59,250 → $56,625 |
| How that refresh ran | Incremental: `sbn_jobs` 48 rows, the report 26 rows of 7,350; about 25 s for the whole chain |
| `04_validate.sql` | All checks pass |
| Location master truncated and reloaded (like the Openflow connector) | Refresh succeeded; report unchanged |

**Not verified:** results on WKS's real data.
