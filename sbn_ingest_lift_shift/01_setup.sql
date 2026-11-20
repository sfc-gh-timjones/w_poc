-- =====================================================================
-- STEP 1 of 4: one-time setup
-- Run in a Snowsight SQL worksheet as ACCOUNTADMIN.
--
-- Before running: replace <SBN_USERNAME> and <SBN_PASSWORD> (the two values in sbn.env).
-- To use a different database/schema: change the two names right below, in
-- every numbered script, and in code_bundle/code_bundle.yml (lines marked <<<).
-- =====================================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS WKS_POC;
USE DATABASE WKS_POC;
CREATE SCHEMA IF NOT EXISTS SBN_LIFT_SHIFT COMMENT = 'SBN ingest: code, secret, stages, and the SBN dataset table';
USE SCHEMA SBN_LIFT_SHIFT;

-- ---------- Account-level objects (not tied to the database/schema) ----------

-- Warehouse for the SQL the notebook runs (reading/writing the dataset table)
CREATE WAREHOUSE IF NOT EXISTS INGESTION_WH
  WAREHOUSE_SIZE = XSMALL
  GENERATION = '2'
  AUTO_SUSPEND = 30
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Data ingestion jobs (SBN notebook)';
USE WAREHOUSE INGESTION_WH;

-- Compute pool the notebook's Python runs on. CPU_X64_XS (1 vCPU, 6 GiB) is the smallest size.
CREATE COMPUTE POOL IF NOT EXISTS INGESTION_POOL
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_XS
  AUTO_RESUME = TRUE
  AUTO_SUSPEND_SECS = 300
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Data ingestion jobs (SBN notebook)';

-- ---------- Objects in the current database/schema ----------

-- SBN credentials (replaces sbn.env). The notebook reads this secret.
CREATE OR REPLACE SECRET SBN_CREDENTIALS
  TYPE = PASSWORD
  USERNAME = '<SBN_USERNAME>'
  PASSWORD = '<SBN_PASSWORD>'
  COMMENT = 'SBN API login used by SBN_Completed_Inspections_Daily';

-- Network rule: allow outbound traffic to the SBN API host only (sbn_common.DEFAULT_BASE_URL)
CREATE NETWORK RULE IF NOT EXISTS SBN_API_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('wks.simplebutneeded.net:443')
  COMMENT = 'SBN API host';

-- External access integration: attaches the network rule (and secret) to the notebook.
-- Snowflake blocks outbound internet calls unless an integration like this allows them.
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION SBN_API_EAI
  ALLOWED_NETWORK_RULES = (SBN_API_NETWORK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (SBN_CREDENTIALS)
  ENABLED = TRUE
  COMMENT = 'Outbound HTTPS to the SBN API';

-- Stage that holds the code files (you upload them here in step 2).
-- Both stages: server-side encryption (SNOWFLAKE_SSE) and a directory table, so files are browsable in Snowsight.
CREATE STAGE IF NOT EXISTS BUNDLE_SRC
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Source files for the SBN_DAILY Code Bundle (contents of code_bundle/)';

-- Stage used as the notebook's working folder, so ./state/last_row_count.txt persists between runs
CREATE STAGE IF NOT EXISTS NOTEBOOK_STATE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Working folder for the SBN notebook (holds ./state)';

-- Check
SHOW WAREHOUSES LIKE 'INGESTION_WH';
SHOW COMPUTE POOLS LIKE 'INGESTION_POOL';
SHOW INTEGRATIONS LIKE 'SBN_API_EAI';
SHOW SECRETS IN SCHEMA;
SHOW STAGES IN SCHEMA;
