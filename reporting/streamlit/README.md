# Streamlit Compliance Report

A live Streamlit-in-Snowflake version of the WKS Safety Compliance Report. Queries `WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT` on every page load, so it is always current after the 4 AM SBN ingest — no manual refresh or re-publish needed.

## Files

| File | What it is |
|---|---|
| `compliance_report.py` | The Streamlit app (single file, self-contained) |
| `01_setup.sql` | Creates the Snowflake objects and deploys the app |

## Run in this order

**Step 1 — Upload the Python file to the stage**

```bash
snow stage copy reporting/streamlit/compliance_report.py \
    @WKS_POC.REPORTING.STREAMLIT_STAGE --overwrite -c <your_connection>
```

Or upload via Snowsight: **Data → Stages → STREAMLIT_STAGE → + Files**

**Step 2 — Create the Streamlit object**

Run `01_setup.sql` in a Snowsight SQL worksheet as ACCOUNTADMIN.

**Step 3 — Open the app**

Snowsight → **Projects → Streamlit → WKS_POC → REPORTING → COMPLIANCE_REPORT**

## To update the app

After editing `compliance_report.py`, re-upload the file and the change is live immediately (no need to recreate the Streamlit object):

```bash
snow stage copy reporting/streamlit/compliance_report.py \
    @WKS_POC.REPORTING.STREAMLIT_STAGE --overwrite -c <your_connection>
```

## What the app shows

Identical layout to the HTML report artifact:
- **4 filters:** Compliance Period (defaults to most recent past month), Brand, District, Location (cascades)
- **3 KPI tiles:** Locations Shown, Fully Compliant %, Total Chargeback
- **Grouped compliance table:** district name on first store row, blue district TOTAL rows, Grand Total row; Completed cells green, Missing cells red

## Notes

- **Live data:** queries `RISK_COMPLIANCE_REPORT` on every load. Data is filtered to `compliance_month <= CURRENT_DATE()` so future mock-data periods never appear.
- **Cache:** the data query is cached for 5 minutes (`@st.cache_data(ttl=300)`) so rapid filter changes don't re-query Snowflake each time.
- **WKS_POC.REPORTING schema:** shared with the email tasks (`../html_emails/`). If you ran `html_emails/01_setup.sql` first, the schema and stage already exist — `01_setup.sql` here uses `IF NOT EXISTS` and is safe to run again.
- **Changing the database:** `compliance_report.py` hardcodes `WKS_POC`. If the database name differs, search-and-replace `WKS_POC` in the Python file before uploading.
