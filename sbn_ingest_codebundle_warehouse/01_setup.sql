-- =====================================================================
-- STEP 1 of 5: one-time setup
-- Run in a Snowsight SQL worksheet as ACCOUNTADMIN.
--
-- Before running: replace <SBN_USERNAME> and <SBN_PASSWORD> (the two values in sbn.env).
--
-- DATABASE: all scripts assume the database is WKS_POC. If your database has
-- a different name, replace WKS_POC in every numbered script, in
-- codebundle/code_bundle.yml (lines marked <<<), and in TRANSFORMATIONS/.
-- =====================================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS WKS_POC;
USE DATABASE WKS_POC;

CREATE SCHEMA IF NOT EXISTS SBN_INGEST
  COMMENT = 'SBN ingest (Code Bundle on a warehouse): code, raw VARIANT tables, secret. Separate from SBN_LIFT_SHIFT.';
USE SCHEMA SBN_INGEST;

-- Warehouse: runs the whole job (the Code Bundle's Python and its SQL).
-- No compute pool is needed in this version.
CREATE WAREHOUSE IF NOT EXISTS INGESTION_WH
  WAREHOUSE_SIZE = XSMALL
  GENERATION = '2'
  AUTO_SUSPEND = 30
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Data ingestion jobs (SBN)';
USE WAREHOUSE INGESTION_WH;

-- SBN credentials (replaces sbn.env). The Code Bundle reads this secret.
-- IF NOT EXISTS: re-running this script never overwrites the stored password.
-- To change it later:  ALTER SECRET SBN_CREDENTIALS SET USERNAME = '...' PASSWORD = '...';
CREATE SECRET IF NOT EXISTS SBN_CREDENTIALS
  TYPE = PASSWORD
  USERNAME = '<SBN_USERNAME>'
  PASSWORD = '<SBN_PASSWORD>'
  COMMENT = 'SBN API login used by the SBN_DAILY Code Bundle';

-- Network rule: allow outbound traffic to the SBN API host only
CREATE NETWORK RULE IF NOT EXISTS SBN_INGEST_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('wks.simplebutneeded.net:443')
  COMMENT = 'SBN API host (used by SBN_INGEST_EAI)';

-- External access integration: lets the Code Bundle call the SBN API, using this secret.
-- Snowflake blocks outbound internet calls unless an integration like this allows them.
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION SBN_INGEST_EAI
  ALLOWED_NETWORK_RULES = (SBN_INGEST_NETWORK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (SBN_CREDENTIALS)
  ENABLED = TRUE
  COMMENT = 'Outbound HTTPS to the SBN API for the SBN_DAILY Code Bundle';

-- Stage that the code files are copied to from GitHub (step 3)
CREATE STAGE IF NOT EXISTS BUNDLE_SRC
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Source files for the SBN_DAILY Code Bundle (contents of codebundle/)';

-- Check
SHOW WAREHOUSES LIKE 'INGESTION_WH';
SHOW INTEGRATIONS LIKE 'SBN_INGEST_EAI';
SHOW SECRETS IN SCHEMA;
SHOW STAGES IN SCHEMA;
