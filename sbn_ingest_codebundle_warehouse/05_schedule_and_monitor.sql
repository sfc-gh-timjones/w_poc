-- =====================================================================
-- STEP 5 of 5: schedule the daily run, and monitoring queries
-- Run as ACCOUNTADMIN.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA SBN_INGEST;
USE WAREHOUSE INGESTION_WH;

-- Daily at 4:00 AM Pacific.
-- The task's WAREHOUSE is the warehouse the Code Bundle runs on.
-- A failed run is retried twice; after 3 failed runs in a row the task suspends itself.
CREATE TASK IF NOT EXISTS SBN_DAILY_TASK
  WAREHOUSE = INGESTION_WH
  SCHEDULE = 'USING CRON 0 4 * * * America/Los_Angeles'
  TASK_AUTO_RETRY_ATTEMPTS = 2
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  COMMENT = 'Runs sbn_daily.py (SBN API -> raw VARIANT tables)'
AS
  EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py';

ALTER TASK SBN_DAILY_TASK RESUME;
SHOW TASKS LIKE 'SBN_DAILY_TASK';

-- ---------------------------------------------------------------------
-- Monitoring (re-run any time)
-- ---------------------------------------------------------------------
-- Run history: status, errors, duration.
-- Also in Snowsight: Catalog > WKS_POC > SBN_INGEST > Code Bundles > SBN_DAILY > Run history.
SELECT ENTRYPOINT, STATUS, ERROR_MESSAGE, START_TIME, END_TIME,
       DATEDIFF('second', START_TIME, END_TIME) AS seconds
FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.CODE_BUNDLE_HISTORY(
       BUNDLE_NAME => 'SBN_DAILY', DATABASE => CURRENT_DATABASE(), SCHEMA => CURRENT_SCHEMA()))
ORDER BY START_TIME DESC;

-- Schedule history
SELECT NAME, STATE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'SBN_DAILY_TASK'))
ORDER BY SCHEDULED_TIME DESC;

-- The raw jobs table, and jobs by status (completed, and reopened / not-completed)
SELECT COUNT(*) AS jobs, MAX(MODIFIED) AS latest_change, MAX(LOADED_AT) AS last_loaded FROM SBN_JOBS_RAW;
SELECT PAYLOAD:job_status::VARCHAR AS job_status, COUNT(*) AS jobs FROM SBN_JOBS_RAW GROUP BY 1 ORDER BY 2 DESC;

-- Handy commands
--   Run the schedule now:   EXECUTE TASK SBN_DAILY_TASK;
--   Pause the schedule:     ALTER TASK SBN_DAILY_TASK SUSPEND;
--   Rotate SBN password:    ALTER SECRET SBN_CREDENTIALS SET PASSWORD = '...';

-- ---------------------------------------------------------------------
-- Remove everything (only if you want to tear it all down)
-- ---------------------------------------------------------------------
--   DROP TASK IF EXISTS SBN_DAILY_TASK;
--   DROP SCHEMA IF EXISTS SBN_INGEST;   -- tables, code bundle, stage, secret, network rule, repo
--   DROP INTEGRATION IF EXISTS SBN_INGEST_EAI;
--   DROP WAREHOUSE IF EXISTS INGESTION_WH;     -- only if nothing else uses it
