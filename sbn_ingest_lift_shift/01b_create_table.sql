-- =====================================================================
-- 01b: Create the target table (optional; run after 01_setup.sql)
--
-- The notebook and backfill_seed.py create this table on their own when
-- they write it. This file is for loading data another way first, for
-- example a CSV export from Domo or SBN (see the bottom of this file).
--
-- Column names and types match exactly what the notebook writes. They come
-- from sbn_common.py: REPORT_COLUMNS and cast_schema().
--   id               -> Int64            -> NUMBER(38,0)
--   6 date columns   -> naive UTC        -> TIMESTAMP_NTZ(9)
--   everything else  -> string          -> VARCHAR
-- The writes use REPLACE, so each run re-creates the table with these
-- same types. Keep them unchanged.
--
-- If you switch to the plain name in the notebook, change it here too.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA SBN_LIFT_SHIFT;
USE WAREHOUSE INGESTION_WH;

CREATE TABLE IF NOT EXISTS "SBN | Completed Inspections | RAW" (
    "id"                          NUMBER(38,0),
    "Created Date"                TIMESTAMP_NTZ(9),
    "Job Started Date"            TIMESTAMP_NTZ(9),
    "Last Modified Date"          TIMESTAMP_NTZ(9),
    "Completion Date"             TIMESTAMP_NTZ(9),
    "Start Date"                  TIMESTAMP_NTZ(9),
    "Due Date"                    TIMESTAMP_NTZ(9),
    "Submission Status"           VARCHAR,
    "Inspection Status"           VARCHAR,
    "Checklist Name"              VARCHAR,
    "Creator First Name"          VARCHAR,
    "Creator Last Name"           VARCHAR,
    "Last Modified By First Name" VARCHAR,
    "Last Modified By Last Name"  VARCHAR,
    "Owner First Name"            VARCHAR,
    "Owner Last Name"             VARCHAR,
    "Inspector First Name"        VARCHAR,
    "Inspector Last Name"         VARCHAR,
    "Frequency"                   VARCHAR,
    "Workflow Status"             VARCHAR,
    "Comment"                     VARCHAR,
    "Location Barcode Scanned"    VARCHAR,
    "Location Lv1"                VARCHAR,
    "Location Lv2"                VARCHAR,
    "Location Lv3"                VARCHAR,
    "Location Lv4"                VARCHAR,
    "Location Lv5"                VARCHAR,
    "Location Lv6"                VARCHAR,
    "Location Lv7"                VARCHAR,
    "Location Lv8"                VARCHAR,
    "Location Lv9"                VARCHAR,
    "Location Lv10"               VARCHAR
);

DESCRIBE TABLE "SBN | Completed Inspections | RAW";

-- ---------------------------------------------------------------------
-- Optional: load a CSV into it (template; adjust to the file you get)
-- 1. Upload the CSV to @NOTEBOOK_STATE/import/ in Snowsight
--    (Data > Databases > WKS_POC > SBN_LIFT_SHIFT > Stages > NOTEBOOK_STATE > + Files).
-- 2. Check the timestamp format. sbn_common.py says SBN's CSV export
--    writes Completion Date as 'MM/DD/YYYY HH24:MI:SS' in UTC-7, while
--    this table stores UTC. If the CSV is UTC-7, use the SELECT form
--    below so +7h is added. A Domo export is usually UTC already.
-- 3. Duplicate ids: the notebook keeps one row per id (the latest
--    "Last Modified Date"), so dedupe the CSV the same way before loading.
-- ---------------------------------------------------------------------
-- Simple form: CSV columns already in UTC, header names match the table:
-- COPY INTO "SBN | Completed Inspections | RAW"
--   FROM @NOTEBOOK_STATE/import/
--   FILE_FORMAT = (TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"'
--                  TIMESTAMP_FORMAT = 'AUTO' NULL_IF = ('', 'NULL'))
--   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
--   ON_ERROR = ABORT_STATEMENT;
--
-- SELECT form: shift an SBN-export UTC-7 timestamp to UTC ($n = CSV column position):
-- COPY INTO "SBN | Completed Inspections | RAW" ("id", "Completion Date" /* , ...rest */)
--   FROM (SELECT $1::NUMBER,
--                DATEADD(hour, 7, TO_TIMESTAMP_NTZ($5, 'MM/DD/YYYY HH24:MI:SS')) /* , ... */
--         FROM @NOTEBOOK_STATE/import/)
--   FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"');
--
-- SELECT COUNT(*), MAX("Completion Date") FROM "SBN | Completed Inspections | RAW";
