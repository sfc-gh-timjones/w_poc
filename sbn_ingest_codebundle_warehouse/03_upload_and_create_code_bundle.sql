-- =====================================================================
-- STEP 3 of 5: load the code from GitHub and create the Code Bundle
-- Run as ACCOUNTADMIN.
--
-- PREREQUISITE: GIT_HUB_INTEGRATION must already exist in this account
-- (one-time setup per Snowflake account):
--   CREATE API INTEGRATION IF NOT EXISTS GIT_HUB_INTEGRATION
--     API_PROVIDER = git_https_api
--     API_ALLOWED_PREFIXES = ('https://github.com/')
--     ENABLED = TRUE;
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA SBN_INGEST;
USE WAREHOUSE INGESTION_WH;

-- Connect Snowflake to the GitHub repo and pull the latest commit
CREATE OR REPLACE GIT REPOSITORY WKS_REPO
  API_INTEGRATION = GIT_HUB_INTEGRATION
  ORIGIN = 'https://github.com/sfc-gh-timjones/w_poc';
ALTER GIT REPOSITORY WKS_REPO FETCH;

-- Copy the 3 code files from GitHub into the BUNDLE_SRC stage
COPY FILES
  INTO @BUNDLE_SRC
  FROM @WKS_REPO/branches/main/sbn_ingest_codebundle_warehouse/codebundle/;

-- Should list: code_bundle.yml, sbn_daily.py, sbn_refresh.py
LIST @BUNDLE_SRC;

-- Package the stage contents as a Code Bundle (a versioned snapshot of the files)
CREATE CODE BUNDLE IF NOT EXISTS SBN_DAILY
  FROM @BUNDLE_SRC
  COMMENT = 'SBN API -> raw VARIANT tables (runs on a warehouse)';

SHOW CODE BUNDLES IN SCHEMA;

-- -----------------------------------------------------------------------
-- LATER, after pushing a change to GitHub:
--   ALTER GIT REPOSITORY WKS_REPO FETCH;
--   COPY FILES INTO @BUNDLE_SRC FROM @WKS_REPO/branches/main/sbn_ingest_codebundle_warehouse/codebundle/;
--   ALTER CODE BUNDLE SBN_DAILY ADD VERSION FROM @BUNDLE_SRC;
-- The schedule keeps using the previous version until you add a new one.
-- -----------------------------------------------------------------------
