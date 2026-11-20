-- =====================================================================
-- STEP 4 of 4: check it's working (read-only; run any time)
-- Run as ACCOUNTADMIN, after 03_compliance_dynamic_tables.sql.
--
-- Each check below uses fully qualified names (WKS_POC.TRANSFORMATIONS.table)
-- so individual checks can be run as standalone snippets in a Snowsight
-- worksheet without needing to run 'USE SCHEMA TRANSFORMATIONS' first.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA TRANSFORMATIONS;
USE WAREHOUSE INGESTION_WH;

-- =====================================================================
-- Check 1: every dynamic table should show refresh_mode INCREMENTAL or
-- ADAPTIVE (never FULL) and scheduling_state ACTIVE.
-- =====================================================================
SHOW DYNAMIC TABLES IN SCHEMA WKS_POC.TRANSFORMATIONS;
SELECT
  "name",
  "refresh_mode",
  "scheduling_state",
  "rows",
  "target_lag",
  "data_timestamp"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "created_on";


-- =====================================================================
-- Check 2: latest refresh of each table.
-- INCREMENTAL or NO_DATA (nothing changed) is normal.
-- An error shows in STATE and STATE_MESSAGE.
-- =====================================================================
SELECT
  NAME,
  REFRESH_ACTION,
  STATE,
  STATE_MESSAGE,
  REFRESH_START_TIME,
  DATEDIFF('millisecond', REFRESH_START_TIME, REFRESH_END_TIME) / 1000 AS seconds
FROM TABLE(WKS_POC.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(RESULT_LIMIT => 200))
WHERE SCHEMA_NAME = 'TRANSFORMATIONS'
QUALIFY ROW_NUMBER() OVER (PARTITION BY NAME ORDER BY REFRESH_START_TIME DESC) = 1
ORDER BY REFRESH_START_TIME;


-- =====================================================================
-- Check 3: the report shape.
-- One row per restaurant per compliance month, no duplicates.
-- Chargeback should be between $0 and $750.
-- =====================================================================
SELECT
  COUNT(*)                                                          AS report_rows,
  COUNT(*) - COUNT(DISTINCT "AdpLocationCode", "Compliance Proxy Date") AS duplicate_rows, -- expect 0
  MIN("Compliance Proxy Date")                                       AS first_month,
  MAX("Compliance Proxy Date")                                       AS last_month,
  MIN("Chargeback")                                                  AS min_chargeback,     -- expect 0
  MAX("Chargeback")                                                  AS max_chargeback      -- expect 750
FROM WKS_POC.TRANSFORMATIONS.risk_compliance_report;


-- =====================================================================
-- Check 4: SBN form-days that didn't match an open restaurant.
-- A few is normal (closed or non-restaurant sites in the SBN data).
-- Many means a location code or FranchisorUnit mismatch between SBN
-- and the location master — worth investigating before go-live.
-- =====================================================================
SELECT
  forms.brand,
  COUNT(*)                        AS unmatched_form_days,
  ANY_VALUE(forms.location_level_3) AS example_location
FROM WKS_POC.TRANSFORMATIONS.daily_form_completions AS forms
LEFT JOIN WKS_POC.TRANSFORMATIONS.restaurant_locations AS loc
    ON  loc.franchisor_unit   = IFF(forms.brand IN ('Krispy Kreme', 'Wendy''s'), forms.location_code, NULL)
    OR  loc.adp_location_code = IFF(forms.brand IN ('Krispy Kreme', 'Wendy''s'), NULL, forms.location_code)
WHERE loc.adp_location_code IS NULL
GROUP BY forms.brand
ORDER BY unmatched_form_days DESC;


-- =====================================================================
-- Check 5: quick sanity on the SBN flatten layer.
-- Completed jobs, users and checklists should all have rows.
-- =====================================================================
SELECT
  (SELECT COUNT(*) FROM WKS_POC.TRANSFORMATIONS.sbn_jobs)                    AS all_jobs,
  (SELECT COUNT(*) FROM WKS_POC.TRANSFORMATIONS.sbn_completed_inspections)    AS completed_inspections,
  (SELECT COUNT(*) FROM WKS_POC.TRANSFORMATIONS.sbn_users)                    AS users,
  (SELECT COUNT(*) FROM WKS_POC.TRANSFORMATIONS.sbn_checklists)               AS checklists;


-- =====================================================================
-- Check 6 (OPTIONAL): compare with the lift-and-shift SBN table.
-- Both should have the same completed inspections (apart from ones
-- reopened since the last lift-and-shift run — that version keeps them,
-- this version drops them once they're no longer 'completed').
-- =====================================================================
SELECT
  (SELECT COUNT(*) FROM WKS_POC.SBN_LIFT_SHIFT."SBN | Completed Inspections | RAW")  AS lift_shift_rows,
  (SELECT COUNT(*) FROM WKS_POC.TRANSFORMATIONS.sbn_completed_inspections)             AS this_version_rows,
  (SELECT COUNT(*) FROM (
    SELECT "id" FROM WKS_POC.SBN_LIFT_SHIFT."SBN | Completed Inspections | RAW"
    EXCEPT
    SELECT inspection_id FROM WKS_POC.TRANSFORMATIONS.sbn_completed_inspections
  ))                                                                                   AS only_in_lift_shift,
  (SELECT COUNT(*) FROM (
    SELECT inspection_id FROM WKS_POC.TRANSFORMATIONS.sbn_completed_inspections
    EXCEPT
    SELECT "id" FROM WKS_POC.SBN_LIFT_SHIFT."SBN | Completed Inspections | RAW"
  ))                                                                                   AS only_in_this_version;


-- Handy commands
--   Trigger a refresh now (the report will cascade upstream automatically):
--     ALTER DYNAMIC TABLE WKS_POC.TRANSFORMATIONS.risk_compliance_report REFRESH;
--   Pause / resume automatic refreshes:
--     ALTER DYNAMIC TABLE WKS_POC.TRANSFORMATIONS.risk_compliance_report SUSPEND;
--     ALTER DYNAMIC TABLE WKS_POC.TRANSFORMATIONS.risk_compliance_report RESUME;
--   Remove everything:
--     DROP SCHEMA WKS_POC.TRANSFORMATIONS;
