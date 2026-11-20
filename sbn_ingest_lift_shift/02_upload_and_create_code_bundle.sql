-- =====================================================================
-- STEP 2 of 4: load code from GitHub and create the Code Bundle
--
-- PREREQUISITE: GIT_HUB_INTEGRATION must already exist in this account
-- (one-time setup per Snowflake account, done before running these scripts):
--   CREATE API INTEGRATION IF NOT EXISTS GIT_HUB_INTEGRATION
--     API_PROVIDER = git_https_api
--     API_ALLOWED_PREFIXES = ('https://github.com/')
--     ENABLED = TRUE;
--
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA SBN_LIFT_SHIFT;
USE WAREHOUSE INGESTION_WH;

-- Connect Snowflake to the GitHub repo.
-- GIT_CREDENTIALS is not needed because the repo is public.
-- ALTER FETCH (below) pulls the latest commit — rerun whenever you push changes.
CREATE OR REPLACE GIT REPOSITORY WKS_REPO
  API_INTEGRATION = GIT_HUB_INTEGRATION
  ORIGIN = 'https://github.com/sfc-gh-timjones/w_poc';

-- Pull the latest commit from the main branch
ALTER GIT REPOSITORY WKS_REPO FETCH;

-- Copy the 6 code files from GitHub into the BUNDLE_SRC stage.
-- Snowflake reads the stage when creating the Code Bundle below.
COPY FILES
  INTO @BUNDLE_SRC
  FROM @WKS_REPO/branches/main/sbn_ingest_lift_shift/code_bundle/;

-- Verify the files arrived (should list the 6 code files)
LIST @BUNDLE_SRC;

-- Package the stage contents as a Code Bundle.
-- A Code Bundle is a versioned snapshot: the schedule always runs the
-- last version, so changing a file has no effect until you add a new version.
CREATE CODE BUNDLE IF NOT EXISTS SBN_DAILY
  FROM @BUNDLE_SRC
  COMMENT = 'SBN_Completed_Inspections_Daily.ipynb + sbn_common.py';

SHOW CODE BUNDLES IN SCHEMA;

-- -----------------------------------------------------------------------
-- LATER, after pushing changes to GitHub and wanting to pick them up:
-- -----------------------------------------------------------------------
--   ALTER GIT REPOSITORY WKS_REPO FETCH;
--   COPY FILES INTO @BUNDLE_SRC FROM @WKS_REPO/branches/main/sbn_ingest_lift_shift/code_bundle/;
--   ALTER CODE BUNDLE SBN_DAILY ADD VERSION FROM @BUNDLE_SRC;
