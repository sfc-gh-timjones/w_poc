-- =====================================================================
-- STEP 1 of 4: one-time setup
-- Run in a Snowsight SQL worksheet as ACCOUNTADMIN, after the SBN ingest
-- (../sbn_ingest_codebundle_warehouse/) has loaded its raw tables.
--
-- Creates the TRANSFORMATIONS schema. Everything in it is a dynamic
-- table: Snowflake keeps each one up to date from its inputs, so there are
-- no tasks or scripts to schedule here.
--
-- Inputs (all must already exist):
--   WKS_POC.SBN_INGEST.SBN_JOBS_RAW / SBN_USERS_RAW / SBN_CHECKLISTS_RAW     (SBN API, raw JSON)
--   WKS_POC.G_SHEET.SHEETS__LOCATION_MASTER                       (Google Sheets, Openflow)
--   WKS_POC.PUBLIC.WKS_FISCAL_CALENDAR_WITH_DATE_DIMS             (loaded in the UI)
--   WKS_POC.WKS_PLUS.WKS_PLUS_PROGRESS_REPORT_RAW                 (WKS+ progress report)
-- If any of these live somewhere else, change the names in 02 and 03.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE WAREHOUSE INGESTION_WH;

-- Increase Time Travel from the 1-day default to 7 days, so accidental changes
-- or bad refreshes can be recovered further back.
ALTER ACCOUNT SET DATA_RETENTION_TIME_IN_DAYS = 7;

CREATE SCHEMA IF NOT EXISTS TRANSFORMATIONS
  COMMENT = 'SBN raw JSON -> flattened tables -> Risk | Compliance Report, all as dynamic tables';

-- Dynamic tables refresh from the changes in their inputs, which needs change
-- tracking on each input table. Snowflake turns it on automatically when the
-- dynamic tables are created (the owner role needs OWNERSHIP of the inputs);
-- turning it on here makes that explicit. It doesn't change the data.
-- DATA_RETENTION_TIME_IN_DAYS = 7 gives 7 days of Time Travel on each input.
ALTER TABLE WKS_POC.SBN_INGEST.SBN_JOBS_RAW                       SET CHANGE_TRACKING = TRUE DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER TABLE WKS_POC.SBN_INGEST.SBN_USERS_RAW                      SET CHANGE_TRACKING = TRUE DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER TABLE WKS_POC.SBN_INGEST.SBN_CHECKLISTS_RAW                 SET CHANGE_TRACKING = TRUE DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER TABLE WKS_POC.G_SHEET.SHEETS__LOCATION_MASTER               SET CHANGE_TRACKING = TRUE DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER TABLE WKS_POC.PUBLIC.WKS_FISCAL_CALENDAR_WITH_DATE_DIMS     SET CHANGE_TRACKING = TRUE DATA_RETENTION_TIME_IN_DAYS = 7;
ALTER TABLE WKS_POC.WKS_PLUS.WKS_PLUS_PROGRESS_REPORT_RAW        SET CHANGE_TRACKING = TRUE DATA_RETENTION_TIME_IN_DAYS = 7;

-- Check that all inputs are there (each should return a row count, not an error)
SELECT 'SBN_JOBS_RAW' AS input, COUNT(*) AS row_count FROM WKS_POC.SBN_INGEST.SBN_JOBS_RAW
UNION ALL SELECT 'SBN_USERS_RAW',                           COUNT(*) FROM WKS_POC.SBN_INGEST.SBN_USERS_RAW
UNION ALL SELECT 'SBN_CHECKLISTS_RAW',                      COUNT(*) FROM WKS_POC.SBN_INGEST.SBN_CHECKLISTS_RAW
UNION ALL SELECT 'SHEETS__LOCATION_MASTER',            COUNT(*) FROM WKS_POC.G_SHEET.SHEETS__LOCATION_MASTER
UNION ALL SELECT 'WKS_FISCAL_CALENDAR_WITH_DATE_DIMS', COUNT(*) FROM WKS_POC.PUBLIC.WKS_FISCAL_CALENDAR_WITH_DATE_DIMS
UNION ALL SELECT 'WKS_PLUS_PROGRESS_REPORT_RAW',       COUNT(*) FROM WKS_POC.WKS_PLUS.WKS_PLUS_PROGRESS_REPORT_RAW;
