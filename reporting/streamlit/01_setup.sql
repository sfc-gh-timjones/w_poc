-- =====================================================================
-- STEP 1 of 1: deploy the Streamlit compliance report app.
-- Run as ACCOUNTADMIN in a Snowsight SQL worksheet.
--
-- DATABASE: all objects go in WKS_POC. The email reporting setup
-- (reporting/html_emails/01_setup.sql) also uses this schema; run
-- that first if you haven't already — it creates WKS_POC.REPORTING
-- and the stage.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE WAREHOUSE INGESTION_WH;

-- If you skipped html_emails setup, create the schema and stage here:
CREATE SCHEMA IF NOT EXISTS WKS_POC.REPORTING
  COMMENT = 'WKS compliance reporting objects (email tasks, Streamlit app)';

CREATE STAGE IF NOT EXISTS WKS_POC.REPORTING.STREAMLIT_STAGE
  DIRECTORY  = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT    = 'Source files for WKS reporting stored procedures and Streamlit';

USE SCHEMA REPORTING;

-- ---------------------------------------------------------------------
-- Step 1: Upload compliance_report.py from this folder to the stage.
-- Run this in a terminal where you have the snow CLI available.
--
--   snow stage copy reporting/streamlit/compliance_report.py \
--       @WKS_POC.REPORTING.STREAMLIT_STAGE --overwrite -c <your_connection>
--
-- Or upload via Snowsight: Data > Stages > STREAMLIT_STAGE > + Files
-- ---------------------------------------------------------------------

-- Step 2: Verify the file is there
LIST @WKS_POC.REPORTING.STREAMLIT_STAGE PATTERN='.*compliance.*';

-- Step 3: Create the Streamlit app object
CREATE STREAMLIT IF NOT EXISTS WKS_POC.REPORTING.COMPLIANCE_REPORT
  ROOT_LOCATION = '@WKS_POC.REPORTING.STREAMLIT_STAGE'
  MAIN_FILE     = 'compliance_report.py'
  QUERY_WAREHOUSE = INGESTION_WH
  COMMENT       = 'Live WKS Risk | Compliance Report — queries TRANSFORMATIONS.RISK_COMPLIANCE_REPORT on every load';

-- Step 4: Grant access (optional — give other roles the ability to view)
-- GRANT USAGE ON STREAMLIT WKS_POC.REPORTING.COMPLIANCE_REPORT TO ROLE SYSADMIN;

-- Check
SHOW STREAMLITS IN SCHEMA WKS_POC.REPORTING;

-- To open the app:
--   Snowsight > Projects > Streamlit > WKS_POC > REPORTING > COMPLIANCE_REPORT
--   Or get the URL from the SHOW output above.
