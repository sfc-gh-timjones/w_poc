-- =====================================================================
-- STEP 3 of 4: one-time history load, then the first daily run
-- Run as ACCOUNTADMIN.
--
-- WHY EACH EXECUTE TAKES ~2 MINUTES (this is expected, not Snowflake running slow)
-- Every EXECUTE CODE BUNDLE starts a fresh, isolated container for that one run,
-- even when the compute pool is already running. Most of the time is that
-- start-up, not the code. Measured in testing (totals from run history):
--   History load:  ~174s
--   Daily run:     ~105-118s
-- Estimated breakdown of each run (not measured individually):
--   Container start-up      ~40-60s  the runtime image (V2.9-CPU-PY3.12) is several
--                                    GB; it's verified or pulled, then a container
--                                    is created. Happens on every run.
--   Jupyter kernel start    ~20-30s  .ipynb entrypoints only: a notebook kernel
--                                    starts before the first cell runs.
--   Python + imports        ~10s     loading pandas, Snowpark, requests, etc.
--   Actual work             the rest  history load: ~19 monthly API pulls, each
--                                    with two count checks; daily: one 30-day pull
--                                    plus the write. Real SBN API speed will vary.
-- A suspended compute pool adds its own start-up on top (a few minutes) the
-- first time; it then stays up for 5 minutes after the last run.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA SBN_LIFT_SHIFT;
USE WAREHOUSE INGESTION_WH;

-- ---------------------------------------------------------------------
-- 3a. Seed "SBN | Completed Inspections | RAW" (same job as the Backfill
--     notebook in Domo). The daily notebook expects this dataset to exist
--     and aborts if it doesn't. Pick ONE option:
--
-- Option A: port SBN_Completed_Inspections_Backfill.ipynb the same way as
--   the daily notebook (add the same "Snowflake port" block to its first
--   code cell), upload it to BUNDLE_SRC, run
--   ALTER CODE BUNDLE SBN_DAILY ADD VERSION FROM @BUNDLE_SRC; and then:
--   EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'SBN_Completed_Inspections_Backfill.ipynb';
--
-- Option B: the included backfill_seed.py (built only from sbn_common.py's
--   own functions; pulls ~18 months, month by month):
EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'backfill_seed.py';
-- ---------------------------------------------------------------------

SELECT COUNT(*) AS seeded_rows FROM "SBN | Completed Inspections | RAW";

-- 3b. First daily run, on demand
EXECUTE CODE BUNDLE SBN_DAILY ENTRYPOINT = 'SBN_Completed_Inspections_Daily.ipynb';

SELECT COUNT(*) AS total_rows, MIN("Completion Date") AS first_completion, MAX("Completion Date") AS last_completion
FROM "SBN | Completed Inspections | RAW";
