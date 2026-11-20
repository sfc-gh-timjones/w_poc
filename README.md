# WKS → Snowflake POC

Two packages for migrating the daily SBN ingest and the Risk | Compliance Report from Domo to Snowflake.

| Folder | What it is |
|---|---|
| [`sbn_ingest_lift_shift/`](sbn_ingest_lift_shift/) | **Lift and shift.** Runs WKS's existing `SBN_Completed_Inspections_Daily.ipynb` and `sbn_common.py` on Snowflake unchanged (8 lines added to the notebook). Start with its [README](sbn_ingest_lift_shift/README.md). |
| [`sbn_ingest_codebundle_warehouse/`](sbn_ingest_codebundle_warehouse/) | **The version to implement.** A Code Bundle on a warehouse that lands the SBN API's JSON as-is in VARIANT tables (schema `SBN_INGEST`). Starts in 5–10 s. Start with its [README](sbn_ingest_codebundle_warehouse/README.md). |
| [`TRANSFORMATIONS/`](TRANSFORMATIONS/) | **The Risk \| Compliance Report as dynamic tables.** Flattens the raw SBN JSON and builds `risk_compliance_report` from the Magic ETL (schema `TRANSFORMATIONS`). Requires `sbn_ingest_codebundle_warehouse` to be running first. Start with its [README](TRANSFORMATIONS/README.md). |

Run `sbn_ingest_lift_shift` first to prove out the credentials and connectivity, then set up `sbn_ingest_codebundle_warehouse` + `TRANSFORMATIONS` as the production pipeline.
