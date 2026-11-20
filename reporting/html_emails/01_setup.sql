-- =====================================================================
-- STEP 1 of 3: one-time setup for WKS compliance email reporting.
-- Run as ACCOUNTADMIN in a Snowsight SQL worksheet.
--
-- Creates:
--   WKS_COMPLIANCE_EMAIL_INT  — email notification integration
--   WKS_POC.REPORTING         — schema for email + Streamlit objects
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE WAREHOUSE INGESTION_WH;

-- Email notification integration.
-- Without ALLOWED_RECIPIENTS, emails go to any verified address in the account.
-- To restrict to specific addresses, add: ALLOWED_RECIPIENTS = ('a@b.com', ...)
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS WKS_COMPLIANCE_EMAIL_INT
  TYPE = EMAIL
  ENABLED = TRUE
  COMMENT = 'WKS compliance report daily emails';

-- ---------------------------------------------------------------------
-- Schema: shared by the email stored procedure, tasks, and Streamlit app.
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS WKS_POC.REPORTING
  COMMENT = 'WKS compliance reporting objects (email tasks, Streamlit app)';

USE SCHEMA REPORTING;

-- Check
SHOW INTEGRATIONS LIKE 'WKS_COMPLIANCE_EMAIL_INT';
SHOW SCHEMAS  LIKE 'REPORTING' IN DATABASE WKS_POC;
