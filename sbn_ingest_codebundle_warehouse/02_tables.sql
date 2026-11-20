-- =====================================================================
-- STEP 2 of 5: the raw tables
-- Run as ACCOUNTADMIN.
--
-- The Code Bundle lands the SBN API's JSON, as-is, in three VARIANT tables.
-- Nothing is flattened here: turning the JSON into report columns is done
-- later, downstream, from these tables.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA SBN_INGEST;
USE WAREHOUSE INGESTION_WH;

-- ---------------------------------------------------------------------
-- Raw tables. Created once, never re-created, so grants, policies and
-- dynamic tables built on them keep working. CHANGE_TRACKING lets the
-- dynamic tables in ../TRANSFORMATIONS/ refresh incrementally.
-- ---------------------------------------------------------------------

-- One row per SBN job (any status), the API's JSON as-is.
-- Reopened jobs stay here with their new status (payload:job_status).
CREATE TABLE IF NOT EXISTS SBN_JOBS_RAW (
  ID        NUMBER(38,0) NOT NULL PRIMARY KEY,   -- informational; the MERGE keeps it unique
  MODIFIED  TIMESTAMP_NTZ(9),                    -- the job's "modified" in UTC (for convenience)
  PAYLOAD   VARIANT,                             -- the full job record from /inspection/job/
  LOADED_AT TIMESTAMP_LTZ(9)                     -- when this version was written
)
CHANGE_TRACKING = TRUE
COMMENT = 'SBN jobs, raw API JSON, one row per id. Loaded by the SBN_DAILY Code Bundle (MERGE on id).';

-- Users and checklists: small lookup lists, replaced in full on every run.
CREATE TABLE IF NOT EXISTS SBN_USERS_RAW (
  ID NUMBER(38,0), PAYLOAD VARIANT, LOADED_AT TIMESTAMP_LTZ(9)
)
CHANGE_TRACKING = TRUE
COMMENT = 'SBN users (/core/user/), raw JSON. Refreshed in full by the SBN_DAILY Code Bundle.';

CREATE TABLE IF NOT EXISTS SBN_CHECKLISTS_RAW (
  ID NUMBER(38,0), PAYLOAD VARIANT, LOADED_AT TIMESTAMP_LTZ(9)
)
CHANGE_TRACKING = TRUE
COMMENT = 'SBN checklists (/inspection/checklist/), raw JSON. Refreshed in full by the SBN_DAILY Code Bundle.';

-- ---------------------------------------------------------------------
-- Helper function used by the MERGE and by the sbn_jobs dynamic table.
--
-- Converts the SBN API's ISO 8601 timestamp strings to UTC TIMESTAMP_NTZ.
-- Mirrors Grace's sbn_common.py _to_naive_utc():
--   pd.to_datetime(series, utc=True, errors="coerce", format="mixed")
--   .dt.tz_localize(None)
--
-- Three cases (matched in order):
--   1. NULL / JSON null / blank              → NULL
--   2. Date-only  "YYYY-MM-DD"               → midnight UTC (00:00:00)
--      MUST come before the tz-regex check:
--      "2026-11-15" ends in "-15", which the tz regex matches as a ±HH offset.
--      If we let it fall through, TRY_TO_TIMESTAMP_TZ applies the *session*
--      timezone (e.g. -07:00), and CONVERT_TIMEZONE shifts the date by hours.
--      Grace's pandas utc=True treats date-only strings as already UTC.
--   3. Full timestamp with tz marker (Z/±HH) → convert to UTC, strip tz
--   4. Full timestamp without tz marker      → treat as already UTC (like pandas)
--
-- IMMUTABLE: all operations are deterministic (no CURRENT_TIMESTAMP etc.),
-- which lets dynamic tables refresh incrementally without re-evaluating this
-- function unnecessarily.
--
-- NOTE: if this function is later changed with CREATE OR REPLACE, any dynamic
-- table in TRANSFORMATIONS that calls it (sbn_jobs) may REINITIALIZE (full
-- recompute). For the initial deploy this is not an issue. For updates, plan
-- to re-create the DTs after updating the function.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION SBN_TS(V VARIANT)
  RETURNS TIMESTAMP_NTZ(9)
  IMMUTABLE
AS
$$
  CASE
    -- 1. NULL / JSON null / blank → NULL
    WHEN V IS NULL OR IS_NULL_VALUE(V) OR TRIM(V::VARCHAR) = '' THEN NULL
    -- 2. Date-only "YYYY-MM-DD" → midnight UTC
    --    Must come BEFORE the tz-regex check to avoid the session-timezone bug.
    WHEN REGEXP_LIKE(TRIM(V::VARCHAR), '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
      THEN TRY_TO_DATE(TRIM(V::VARCHAR))::TIMESTAMP_NTZ(9)
    -- 3. Full timestamp with tz offset or 'Z' → convert to UTC
    WHEN REGEXP_LIKE(TRIM(V::VARCHAR), '.*(Z|z|[+-][0-9]{2}(:?[0-9]{2})?)$')
      THEN CONVERT_TIMEZONE('UTC', TRY_TO_TIMESTAMP_TZ(TRIM(V::VARCHAR)))::TIMESTAMP_NTZ(9)
    -- 4. Full timestamp without tz → treat as UTC (same as pandas utc=True on naive strings)
    ELSE TRY_TO_TIMESTAMP_NTZ(TRIM(V::VARCHAR))
  END
$$;

SHOW TABLES IN SCHEMA;
