# HTML Compliance Emails

Sends a daily HTML compliance report email — the same data as the Snowflake artifact report — via Snowflake Tasks. Three tasks cover three areas of WKS restaurants.

## Run in this order

| Step | File | What it does |
|---|---|---|
| 1 | `01_setup.sql` | Creates the email notification integration, `WKS_POC.REPORTING` schema, and stage |
| 2 | `02_email_procedure.sql` | Creates `SEND_COMPLIANCE_EMAIL(area_filter, recipient)` stored procedure |
| 3 | `03_tasks.sql` | Creates and resumes 3 daily tasks (one per area, 5 AM Pacific) |

## Before running

1. **Add recipient addresses** to `ALLOWED_RECIPIENTS` in `01_setup.sql`.  Every address that will receive email must be listed here.
2. **Update `<RECIPIENT_EMAIL>`** in `03_tasks.sql` for each task. Each task can send to a different address.

## What the email looks like

An HTML table with the same columns as the Domo report:

```
District Leader | Location | Form 1 | Form 2 | Form 3 | WKS+ % | Total % | Chargeback
```

Cells are color-coded green (Completed) and red (Missing), matching the Domo design. The email shows only the **most recent past compliance period** — it always uses the latest data.

## Three tasks (by area)

| Task | Area filter | Districts covered |
|---|---|---|
| `COMPLIANCE_EMAIL_AREA1` | `% | Area 1` | 1, 5, 9 |
| `COMPLIANCE_EMAIL_AREA2` | `% | Area 2` | 2, 6, 10 |
| `COMPLIANCE_EMAIL_AREA3` | `% | Area 3` | 3, 7, 11 |

**Schedule:** 5:00 AM Pacific daily (1 hour after the 4 AM SBN ingest, so data is always current).

## To test immediately

After running all 3 steps:

```sql
EXECUTE TASK WKS_POC.REPORTING.COMPLIANCE_EMAIL_AREA1;
EXECUTE TASK WKS_POC.REPORTING.COMPLIANCE_EMAIL_AREA2;
EXECUTE TASK WKS_POC.REPORTING.COMPLIANCE_EMAIL_AREA3;
```

## Monitoring

```sql
SELECT NAME, STATE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
  TASK_NAME => 'COMPLIANCE_EMAIL_AREA1'
))
ORDER BY SCHEDULED_TIME DESC;
```

## Notes

- The stored procedure uses `SYSTEM$SEND_EMAIL`, which requires the notification integration created in step 1.
- The `WKS_POC.REPORTING` schema is shared with the Streamlit app (`../streamlit/`). Run `01_setup.sql` only once.
- To add a 4th task for Area 4 (Districts 4, 8, 12), copy any task block in `03_tasks.sql` and change the filter to `'% | Area 4'`.
