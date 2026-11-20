-- =====================================================================
-- WKS Compliance Dashboard — Tile SQL
-- =====================================================================
-- These queries back each tile in the Snowflake Dashboard 2.0.
-- To build the dashboard in Snowsight:
--   1. Open Workspaces → Create → Dashboard  (or type /dashboard in CoCo)
--   2. Paste each query below into a new tile, choose the chart type noted.
--   3. Add the filters defined at the bottom of this file.
--   4. See README.md for the full step-by-step walkthrough.
--
-- Filter placeholders used:  {{ filter('compliance_period') }}
--                             {{ filter('brand') }}
--                             {{ filter('district') }}
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE WAREHOUSE INGESTION_WH;


-- ─────────────────────────────────────────────────────────────────────
-- TILE 1 — Scorecard: Total Locations
-- Chart type: Scorecard  |  Field: LOCATION_COUNT
-- ─────────────────────────────────────────────────────────────────────
SELECT COUNT(*) AS LOCATION_COUNT
FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
WHERE "FranchisorAbbr" <> 'CWD'
  AND {{ filter('compliance_period') }}
  AND {{ filter('brand') }}
  AND {{ filter('district') }};


-- ─────────────────────────────────────────────────────────────────────
-- TILE 2 — Scorecard: Fully Compliant %
-- Chart type: Scorecard  |  Field: FULLY_COMPLIANT_PCT
-- (all 4 items complete: 3 forms + WKS+ training ≥ 90%)
-- ─────────────────────────────────────────────────────────────────────
SELECT
  ROUND(100.0 *
    COUNT_IF(
      "Monthly Employee Safety Behavior Observation Form Encoded" = 1
      AND "Monthly Safety Committee Meeting Form Encoded"         = 1
      AND "Monthly Store Inspection Form Encoded"                 = 1
      AND "WKS+ Completion Encoded"                               = 1
    ) / NULLIF(COUNT(*), 0), 1
  ) AS FULLY_COMPLIANT_PCT
FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
WHERE "FranchisorAbbr" <> 'CWD'
  AND {{ filter('compliance_period') }}
  AND {{ filter('brand') }}
  AND {{ filter('district') }};


-- ─────────────────────────────────────────────────────────────────────
-- TILE 3 — Scorecard: Total Chargeback
-- Chart type: Scorecard  |  Field: TOTAL_CHARGEBACK
-- ─────────────────────────────────────────────────────────────────────
SELECT SUM("Chargeback") AS TOTAL_CHARGEBACK
FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
WHERE "FranchisorAbbr" <> 'CWD'
  AND {{ filter('compliance_period') }}
  AND {{ filter('brand') }}
  AND {{ filter('district') }};


-- ─────────────────────────────────────────────────────────────────────
-- TILE 4 — Bar chart: Chargeback by District
-- Chart type: Bar chart  |  X: DISTRICT  |  Y: TOTAL_CHARGEBACK
-- Sort: Y descending
-- ─────────────────────────────────────────────────────────────────────
SELECT
  "District Leader & Area Filter"  AS DISTRICT,
  SUM("Chargeback")                AS TOTAL_CHARGEBACK
FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
WHERE "FranchisorAbbr" <> 'CWD'
  AND {{ filter('compliance_period') }}
  AND {{ filter('brand') }}
  AND {{ filter('district') }}
GROUP BY DISTRICT
ORDER BY TOTAL_CHARGEBACK DESC;


-- ─────────────────────────────────────────────────────────────────────
-- TILE 5 — Bar chart: Compliance by Brand
-- Chart type: Bar chart (grouped or stacked)  |  X: BRAND  |  Y: counts
-- Shows how many locations are fully compliant vs not, per brand
-- ─────────────────────────────────────────────────────────────────────
SELECT
  "FranchisorAbbr"  AS BRAND,
  COUNT_IF(
    "Monthly Employee Safety Behavior Observation Form Encoded" = 1
    AND "Monthly Safety Committee Meeting Form Encoded"         = 1
    AND "Monthly Store Inspection Form Encoded"                 = 1
    AND "WKS+ Completion Encoded"                               = 1
  )                 AS FULLY_COMPLIANT,
  COUNT_IF(NOT (
    "Monthly Employee Safety Behavior Observation Form Encoded" = 1
    AND "Monthly Safety Committee Meeting Form Encoded"         = 1
    AND "Monthly Store Inspection Form Encoded"                 = 1
    AND "WKS+ Completion Encoded"                               = 1
  ))                AS NOT_COMPLIANT,
  COUNT(*)          AS TOTAL_LOCATIONS
FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
WHERE "FranchisorAbbr" <> 'CWD'
  AND {{ filter('compliance_period') }}
  AND {{ filter('district') }}
GROUP BY BRAND
ORDER BY BRAND;


-- ─────────────────────────────────────────────────────────────────────
-- TILE 6 — Table: Full compliance detail
-- Chart type: Table
-- This is the main detail table, one row per location per period.
-- ─────────────────────────────────────────────────────────────────────
SELECT
  "District Leader & Area Filter"                                AS "District",
  "LocationDesc"                                                 AS "Location",
  "Monthly Employee Safety Behavior Observation Form Completion" AS "Employee Safety Obs",
  "Monthly Safety Committee Meeting Form Completion"             AS "Safety Committee Mtg",
  "Monthly Store Inspection Form Completion"                     AS "Store Inspection",
  CASE WHEN "WKS+ Completion" IS NULL THEN '—'
       ELSE ROUND("WKS+ Completion" * 100, 0)::VARCHAR || '%'
  END                                                            AS "WKS+ Completion",
  ROUND(
    ("Monthly Employee Safety Behavior Observation Form Encoded"
     + "Monthly Safety Committee Meeting Form Encoded"
     + "Monthly Store Inspection Form Encoded"
     + "WKS+ Completion Encoded") / 4.0 * 100, 0
  )::VARCHAR || '%'                                              AS "Total %",
  "Chargeback"                                                   AS "Chargeback"
FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
WHERE "FranchisorAbbr" <> 'CWD'
  AND {{ filter('compliance_period') }}
  AND {{ filter('brand') }}
  AND {{ filter('district') }}
ORDER BY "District", "Location";


-- ─────────────────────────────────────────────────────────────────────
-- TILE 7 (optional) — Line chart: Compliance trend over time
-- Chart type: Line chart  |  X: COMPLIANCE_MONTH  |  Y: PCT
-- Shows fully compliant % trending across the last 12 months
-- ─────────────────────────────────────────────────────────────────────
SELECT
  "Compliance Proxy Date"                                        AS COMPLIANCE_MONTH,
  ROUND(100.0 *
    COUNT_IF(
      "Monthly Employee Safety Behavior Observation Form Encoded" = 1
      AND "Monthly Safety Committee Meeting Form Encoded"         = 1
      AND "Monthly Store Inspection Form Encoded"                 = 1
      AND "WKS+ Completion Encoded"                               = 1
    ) / NULLIF(COUNT(*), 0), 1
  )                                                              AS FULLY_COMPLIANT_PCT,
  ROUND(SUM("Chargeback") / 1000, 1)                            AS TOTAL_CHARGEBACK_K
FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
WHERE "FranchisorAbbr" <> 'CWD'
  AND "Compliance Proxy Date" <= CURRENT_DATE()
  AND "Compliance Proxy Date" >= DATEADD(month, -11, DATE_TRUNC('month', CURRENT_DATE()))
  AND {{ filter('brand') }}
  AND {{ filter('district') }}
GROUP BY COMPLIANCE_MONTH
ORDER BY COMPLIANCE_MONTH;


-- =====================================================================
-- FILTERS — define these in the dashboard filter panel
-- =====================================================================
--
-- Filter 1: compliance_period
--   Type: timestamp (single-select, or use the date range mode)
--   Column: "Compliance Proxy Date"  in  RISK_COMPLIANCE_REPORT
--   Suggested default: most recent past month
--   SQL to populate values:
SELECT DISTINCT "Compliance Proxy Date" AS compliance_period_value
FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
WHERE "Compliance Proxy Date" <= CURRENT_DATE()
ORDER BY compliance_period_value DESC;

--
-- Filter 2: brand
--   Type: string (multi-select)
--   Column: "FranchisorAbbr"  in  RISK_COMPLIANCE_REPORT
--   Values (static): DEN, EPL, KK, WEN
--
-- Filter 3: district
--   Type: string (multi-select)
--   Column: "District Leader & Area Filter"  in  RISK_COMPLIANCE_REPORT
--   Source: column (runs SELECT DISTINCT automatically)
