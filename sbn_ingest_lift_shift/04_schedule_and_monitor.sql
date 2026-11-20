-- =====================================================================
-- STEP 4 of 4: schedule the daily run, and monitoring queries
-- Run as ACCOUNTADMIN.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA SBN_LIFT_SHIFT;
USE WAREHOUSE INGESTION_WH;

-- Daily at 5:00 AM Pacific (like the Domo Workspace schedule)
CREATE TASK IF NOT EXISTS SBN_DAILY_TASK
  WAREHOUSE = INGESTION_WH
  SCHEDULE = 'USING CRON 0 5 * * * America/Los_Angeles'
  COMMENT = 'Runs SBN_Completed_Inspections_Daily.ipynb'
AS
  EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'SBN_Completed_Inspections_Daily.ipynb';

ALTER TASK SBN_DAILY_TASK RESUME;
SHOW TASKS LIKE 'SBN_DAILY_TASK';

-- ---------------------------------------------------------------------
-- Monitoring (re-run any time)
-- ---------------------------------------------------------------------
-- Notebook run history: status, errors, duration.
-- Also in Snowsight: Catalog > WKS_POC > SBN_LIFT_SHIFT > Code Bundles > SBN_DAILY > Run history (shows each run's output).
SELECT ENTRYPOINT, STATUS, ERROR_MESSAGE, START_TIME, END_TIME
FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.CODE_BUNDLE_HISTORY(
       BUNDLE_NAME => 'SBN_DAILY', DATABASE => CURRENT_DATABASE(), SCHEMA => CURRENT_SCHEMA()))
ORDER BY START_TIME DESC;

-- Schedule history
SELECT NAME, STATE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'SBN_DAILY_TASK'))
ORDER BY SCHEDULED_TIME DESC;

-- The dataset
SELECT COUNT(*) AS total_rows, MAX("Last Modified Date") AS latest_change
FROM "SBN | Completed Inspections | RAW";

-- Handy commands
--   Run the schedule now:   EXECUTE TASK SBN_DAILY_TASK;
--   Pause the schedule:     ALTER TASK SBN_DAILY_TASK SUSPEND;
--   Rotate SBN password:    ALTER SECRET SBN_CREDENTIALS SET PASSWORD = '...';

-- ---------------------------------------------------------------------
-- Remove everything (only if you want to tear it all down)
-- ---------------------------------------------------------------------
--   DROP TASK IF EXISTS SBN_DAILY_TASK;
--   DROP SCHEMA IF EXISTS SBN_LIFT_SHIFT;               -- table, stages, secret, network rule, code bundle
--   DROP INTEGRATION IF EXISTS SBN_API_EAI;
--   DROP COMPUTE POOL IF EXISTS INGESTION_POOL;
--   DROP WAREHOUSE IF EXISTS INGESTION_WH;
