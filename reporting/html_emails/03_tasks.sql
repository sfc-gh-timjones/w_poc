-- =====================================================================
-- STEP 3 of 3: three daily tasks — each sends a compliance email for
-- one specific district, 1 hour after the 4 AM SBN ingest.
--
-- Run as ACCOUNTADMIN after 02_email_procedure.sql.
--
-- NOTE: The district values below ('District 1 | Area 1' etc.) are from
-- the demo account. Before deploying in Grace's account, verify the
-- actual values:
--   SELECT DISTINCT "District Leader & Area Filter"
--   FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
--   ORDER BY 1;
-- Then update the DISTRICT_FILTER argument in each CALL below.
--
-- To test immediately after creating:
--   EXECUTE TASK WKS_POC.REPORTING.COMPLIANCE_EMAIL_DISTRICT1;
--   EXECUTE TASK WKS_POC.REPORTING.COMPLIANCE_EMAIL_DISTRICT2;
--   EXECUTE TASK WKS_POC.REPORTING.COMPLIANCE_EMAIL_DISTRICT3;
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA REPORTING;
USE WAREHOUSE INGESTION_WH;

-- -----------------------------------------------------------------
-- District 1 | Area 1
-- -----------------------------------------------------------------
CREATE TASK IF NOT EXISTS WKS_POC.REPORTING.COMPLIANCE_EMAIL_DISTRICT1
  WAREHOUSE  = INGESTION_WH
  SCHEDULE   = 'USING CRON 0 6 * * * America/Los_Angeles'
  COMMENT    = 'Daily compliance email for District 1 | Area 1'
AS
  CALL WKS_POC.REPORTING.SEND_COMPLIANCE_EMAIL('District 1 | Area 1', 'grace.brockwell@wksusa.com');

ALTER TASK WKS_POC.REPORTING.COMPLIANCE_EMAIL_DISTRICT1 RESUME;

-- -----------------------------------------------------------------
-- District 2 | Area 2
-- -----------------------------------------------------------------
CREATE TASK IF NOT EXISTS WKS_POC.REPORTING.COMPLIANCE_EMAIL_DISTRICT2
  WAREHOUSE  = INGESTION_WH
  SCHEDULE   = 'USING CRON 0 6 * * * America/Los_Angeles'
  COMMENT    = 'Daily compliance email for District 2 | Area 2'
AS
  CALL WKS_POC.REPORTING.SEND_COMPLIANCE_EMAIL('District 2 | Area 2', 'grace.brockwell@wksusa.com');

ALTER TASK WKS_POC.REPORTING.COMPLIANCE_EMAIL_DISTRICT2 RESUME;

-- -----------------------------------------------------------------
-- District 3 | Area 3
-- -----------------------------------------------------------------
CREATE TASK IF NOT EXISTS WKS_POC.REPORTING.COMPLIANCE_EMAIL_DISTRICT3
  WAREHOUSE  = INGESTION_WH
  SCHEDULE   = 'USING CRON 0 6 * * * America/Los_Angeles'
  COMMENT    = 'Daily compliance email for District 3 | Area 3'
AS
  CALL WKS_POC.REPORTING.SEND_COMPLIANCE_EMAIL('District 3 | Area 3', 'grace.brockwell@wksusa.com');

ALTER TASK WKS_POC.REPORTING.COMPLIANCE_EMAIL_DISTRICT3 RESUME;

-- Check
SHOW TASKS LIKE 'COMPLIANCE_EMAIL_%' IN SCHEMA WKS_POC.REPORTING;
