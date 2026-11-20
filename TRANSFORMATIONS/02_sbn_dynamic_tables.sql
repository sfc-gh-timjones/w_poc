-- =====================================================================
-- STEP 2 of 4: SBN — flatten the raw JSON, then join it
-- Run as ACCOUNTADMIN, after 01_setup.sql.
--
--   SBN_INGEST.SBN_JOBS_RAW      ─ flatten ─ sbn_jobs ─────────┐
--   SBN_INGEST.SBN_USERS_RAW     ─ flatten ─ sbn_users ────────┼─ join ─ sbn_completed_inspections
--   SBN_INGEST.SBN_CHECKLISTS_RAW─ flatten ─ sbn_checklists ───┘
--
-- sbn_completed_inspections is the same data as the Domo dataset
-- "SBN | Completed Inspections | RAW" (one row per completed inspection,
-- names looked up), with plain underscore column names.
--
-- TARGET_LAG = DOWNSTREAM: these refresh whenever a table built on them
-- (the compliance report, step 3) needs them, so they're never refreshed
-- for nothing.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA TRANSFORMATIONS;
USE WAREHOUSE INGESTION_WH;

-- =====================================================================
-- sbn_jobs: one row per SBN job (any status), JSON fields as columns.
--
-- TIMESTAMPS: SBN_TS() converts the API's ISO 8601 strings to UTC TIMESTAMP_NTZ.
--
-- LOCATION LEVELS (location_level_1 .. location_level_10):
--   The SBN API returns location_hierarchy as one tilde-delimited string, e.g.:
--     "Wendy's ~ Region 1 ~ [6240] Wendy's #6240 - Las Vegas, NV"
--   SPLIT(..., '~') produces a Snowflake ARRAY. Array elements are accessed
--   0-based: location_levels[0] is level 1, location_levels[1] is level 2, etc.
--   This separator and the 10-level structure come directly from Grace's
--   original sbn_common.py (split("~") + LOCATION_LEVELS = 10).
--   Overflow: if there are more than 10 parts, parts 10+ are joined back with
--   '~' into level 10, exactly as sbn_common.py does:
--     parts = parts[:9] + ["~".join(parts[9:])]
--
-- LOCATION_CODE: the number between brackets in level 3,
--   e.g. "[6240] Wendy's #6240..." → 6240.
--   This is the "ADP Location Code" in the Magic ETL.
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE sbn_jobs
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = AUTO
  COMMENT = 'SBN jobs (any status), JSON fields as columns, flattened from SBN_INGEST.SBN_JOBS_RAW'
AS
WITH raw_jobs AS (
  SELECT
    ID,
    PAYLOAD,
    SPLIT(PAYLOAD:location_hierarchy::VARCHAR, '~') AS location_levels
  FROM WKS_POC.SBN_INGEST.SBN_JOBS_RAW
)
SELECT
  ID                                                                    AS inspection_id,
  PAYLOAD:job_status::VARCHAR                                           AS inspection_status,
  PAYLOAD:submission_status::VARCHAR                                    AS submission_status,
  PAYLOAD:workflow_status::VARCHAR                                      AS workflow_status,
  WKS_POC.SBN_INGEST.SBN_TS(PAYLOAD:created)                           AS created_at,
  WKS_POC.SBN_INGEST.SBN_TS(PAYLOAD:job_started)                       AS job_started_at,
  WKS_POC.SBN_INGEST.SBN_TS(PAYLOAD:modified)                          AS last_modified_at,
  WKS_POC.SBN_INGEST.SBN_TS(PAYLOAD:completion_date)                   AS completed_at,
  WKS_POC.SBN_INGEST.SBN_TS(PAYLOAD:start_date)                        AS start_at,
  WKS_POC.SBN_INGEST.SBN_TS(PAYLOAD:due_date)                          AS due_at,
  TRY_TO_NUMBER(PAYLOAD:checklist::VARCHAR)                             AS checklist_id,
  TRY_TO_NUMBER(PAYLOAD:created_by::VARCHAR)                            AS created_by_user_id,
  TRY_TO_NUMBER(PAYLOAD:modified_by::VARCHAR)                           AS modified_by_user_id,
  TRY_TO_NUMBER(PAYLOAD:owner::VARCHAR)                                 AS owner_user_id,
  TRY_TO_NUMBER(PAYLOAD:inspector::VARCHAR)                             AS inspector_user_id,
  PAYLOAD:frequency::VARCHAR                                            AS frequency,
  PAYLOAD:comment::VARCHAR                                              AS comment,
  PAYLOAD:location_barcode_scanned::VARCHAR                             AS location_barcode_scanned,
  PAYLOAD:location_hierarchy::VARCHAR                                   AS location_hierarchy,
  NULLIF(TRIM(location_levels[0]::VARCHAR), '')                         AS location_level_1,
  NULLIF(TRIM(location_levels[1]::VARCHAR), '')                         AS location_level_2,
  NULLIF(TRIM(location_levels[2]::VARCHAR), '')                         AS location_level_3,
  NULLIF(TRIM(location_levels[3]::VARCHAR), '')                         AS location_level_4,
  NULLIF(TRIM(location_levels[4]::VARCHAR), '')                         AS location_level_5,
  NULLIF(TRIM(location_levels[5]::VARCHAR), '')                         AS location_level_6,
  NULLIF(TRIM(location_levels[6]::VARCHAR), '')                         AS location_level_7,
  NULLIF(TRIM(location_levels[7]::VARCHAR), '')                         AS location_level_8,
  NULLIF(TRIM(location_levels[8]::VARCHAR), '')                         AS location_level_9,
  -- Level 10: if more than 10 parts, join the extras back with '~' (same as sbn_common.py)
  NULLIF(IFF(ARRAY_SIZE(location_levels) > 10,
             ARRAY_TO_STRING(TRANSFORM(ARRAY_SLICE(location_levels, 9, ARRAY_SIZE(location_levels)),
                                       level VARIANT -> TRIM(level::VARCHAR)), '~'),
             TRIM(location_levels[9]::VARCHAR)), '')                    AS location_level_10,
  -- Extract the numeric code from "[6240] Store name..." → 6240
  TRY_CAST(SUBSTRING(location_level_3, 2, POSITION(']' IN location_level_3) - 2) AS INTEGER)
                                                                        AS location_code
FROM raw_jobs;


-- =====================================================================
-- sbn_users: user id, first name, last name — the lookup for all 4 user
-- FK fields on each job (created_by, modified_by, owner, inspector).
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE sbn_users
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = AUTO
  COMMENT = 'SBN users, flattened from SBN_INGEST.SBN_USERS_RAW'
AS
SELECT
  ID                           AS user_id,
  PAYLOAD:first_name::VARCHAR  AS first_name,
  PAYLOAD:last_name::VARCHAR   AS last_name
FROM WKS_POC.SBN_INGEST.SBN_USERS_RAW;


-- =====================================================================
-- sbn_checklists: checklist id and name — the lookup for the checklist
-- FK on each job.
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE sbn_checklists
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = AUTO
  COMMENT = 'SBN checklists, flattened from SBN_INGEST.SBN_CHECKLISTS_RAW'
AS
SELECT
  ID                     AS checklist_id,
  PAYLOAD:name::VARCHAR  AS checklist_name
FROM WKS_POC.SBN_INGEST.SBN_CHECKLISTS_RAW;


-- =====================================================================
-- sbn_completed_inspections: completed inspections with names resolved.
-- Equivalent to the Domo dataset "SBN | Completed Inspections | RAW".
--
-- Lookup rules (same as sbn_common.py):
--   no id on the job      → NULL
--   id not in the list    → 'user#<id>'  or  'checklist#<id>'
--
-- Reopened jobs (job_status ≠ 'completed') are excluded automatically
-- by the WHERE clause.
--
-- REFRESH_MODE = INCREMENTAL: Snowflake would otherwise pick FULL because
-- this table has 5 joins. All joins are plain equality joins, so incremental
-- is safe — only the rows that changed are reprocessed.
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE sbn_completed_inspections
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = INCREMENTAL
  COMMENT = 'Completed SBN inspections with user and checklist names resolved (was the Domo dataset SBN | Completed Inspections | RAW)'
AS
SELECT
  jobs.inspection_id,
  jobs.created_at,
  jobs.job_started_at,
  jobs.last_modified_at,
  jobs.completed_at,
  jobs.completed_at::DATE                                                                                        AS completed_date,
  jobs.start_at,
  jobs.due_at,
  jobs.submission_status,
  jobs.inspection_status,
  jobs.workflow_status,
  CASE
    WHEN jobs.checklist_id IS NULL     THEN NULL
    WHEN cl.checklist_id   IS NULL     THEN 'checklist#' || jobs.checklist_id
    ELSE                                    cl.checklist_name
  END                                                                                                           AS checklist_name,
  IFF(jobs.created_by_user_id  IS NOT NULL AND cr.user_id  IS NULL, 'user#' || jobs.created_by_user_id,  cr.first_name)   AS created_by_first_name,
  cr.last_name                                                                                                              AS created_by_last_name,
  IFF(jobs.modified_by_user_id IS NOT NULL AND mo.user_id  IS NULL, 'user#' || jobs.modified_by_user_id, mo.first_name)   AS modified_by_first_name,
  mo.last_name                                                                                                              AS modified_by_last_name,
  IFF(jobs.owner_user_id       IS NOT NULL AND ow.user_id  IS NULL, 'user#' || jobs.owner_user_id,       ow.first_name)   AS owner_first_name,
  ow.last_name                                                                                                              AS owner_last_name,
  IFF(jobs.inspector_user_id   IS NOT NULL AND ins.user_id IS NULL, 'user#' || jobs.inspector_user_id,   ins.first_name)  AS inspector_first_name,
  ins.last_name                                                                                                             AS inspector_last_name,
  jobs.frequency,
  jobs.comment,
  jobs.location_barcode_scanned,
  jobs.location_level_1,
  jobs.location_level_2,
  jobs.location_level_3,
  jobs.location_level_4,
  jobs.location_level_5,
  jobs.location_level_6,
  jobs.location_level_7,
  jobs.location_level_8,
  jobs.location_level_9,
  jobs.location_level_10,
  jobs.location_code
FROM sbn_jobs AS jobs
LEFT JOIN sbn_checklists AS cl
    ON cl.checklist_id = jobs.checklist_id
LEFT JOIN sbn_users AS cr
    ON cr.user_id = jobs.created_by_user_id
LEFT JOIN sbn_users AS mo
    ON mo.user_id = jobs.modified_by_user_id
LEFT JOIN sbn_users AS ow
    ON ow.user_id = jobs.owner_user_id
LEFT JOIN sbn_users AS ins
    ON ins.user_id = jobs.inspector_user_id
WHERE jobs.inspection_status = 'completed';

SHOW DYNAMIC TABLES IN SCHEMA;
