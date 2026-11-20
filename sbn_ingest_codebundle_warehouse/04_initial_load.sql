-- =====================================================================
-- STEP 4 of 5: API check, history load, then the first daily run
-- Run as ACCOUNTADMIN.
--
-- All three run the same entrypoint; only the ARGUMENTS differ. The Code
-- Bundle runs on the warehouse set by USE WAREHOUSE below.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA SBN_INGEST;
USE WAREHOUSE INGESTION_WH;      -- the Code Bundle runs on this warehouse

-- 4.0 Read-only API check (writes nothing). The result is in the run's output
--     (Code Bundles > SBN_DAILY > Run history). It fails outright if check 2 fails.
--     The README explains each check and what to do.
EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py' ARGUMENTS = ('--mode', 'check');

-- 4a. History load: ~18 months (560 days), completed jobs pulled month by month
EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py' ARGUMENTS = ('--days-back', '560');

SELECT COUNT(*) AS jobs, COUNT_IF(PAYLOAD:job_status::VARCHAR = 'completed') AS completed_jobs FROM SBN_JOBS_RAW;

-- 4b. First daily run, on demand (default 30-day window)
EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'sbn_daily.py';

SELECT COUNT(*) AS jobs,
       COUNT_IF(PAYLOAD:job_status::VARCHAR = 'completed') AS completed_jobs,
       MAX(MODIFIED) AS latest_change
FROM SBN_JOBS_RAW;


SELECT COUNT(*) as users_table_cnt FROM SBN_USERS_RAW;
SELECT COUNT(*) as checklists_table_cnt FROM SBN_CHECKLISTS_RAW ;
