-- =====================================================================
-- STEP 3 of 4: the Risk | Compliance Report, as dynamic tables
-- Run as ACCOUNTADMIN, after 02_sbn_dynamic_tables.sql.
--
-- The same logic as the Domo Magic ETL "Risk | Compliance Report | PROD"
-- (dataflow 846). Each dynamic table says which Magic ETL tile(s) it replaces.
--
--   SHEETS__LOCATION_MASTER ── restaurant_locations ──────────────────────────────────────────────┐
--                                                       ├─ restaurant_days ─────────────────────┐  │
--   WKS_FISCAL_CALENDAR     ── compliance_calendar ─────┘                                       │  │
--   sbn_completed_inspections ─ daily_form_completions ─ restaurant_form_days ──────────────────┼──┤
--   WKS_PLUS_PROGRESS_REPORT ─ safety_training_by_due_date ─────────────────────────────────────┘  │
--                                                                                   restaurant_days_enriched
--                                                                                              │
--                                                                               risk_compliance_report
--
-- risk_compliance_report has TARGET_LAG = '1 hour': Snowflake keeps it at most
-- an hour behind its inputs, refreshing everything upstream as needed. When
-- nothing upstream changed, a refresh is skipped. Everything else is
-- TARGET_LAG = DOWNSTREAM (refreshed only when the report needs it).
--
-- REFRESH_MODE = INCREMENTAL on the last three tables: Snowflake would pick
-- FULL (recompute everything) for joins this size; incremental reprocesses
-- only what changed, e.g. one day of new inspections.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA TRANSFORMATIONS;
USE WAREHOUSE INGESTION_WH;

-- =====================================================================
-- restaurant_locations   (Magic ETL: Locations MASTER + "Restaurant Only")
-- Open restaurants only, with the columns the compliance calculation needs.
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE restaurant_locations
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = AUTO
  COMMENT = 'Open restaurants from the location master'
AS
SELECT
  "AdpLocationCode"               AS adp_location_code,
  "FranchisorUnit"                AS franchisor_unit,
  "FranchisorAbbr"                AS franchisor_abbr,
  "LocationDesc"                  AS location_name,
  "District Leader & Area Filter" AS district_area,
  "Email"                         AS store_email,
  "DL Email Address"              AS district_leader_email,
  "RegionLeaderName"              AS region_leader_name,
  "St"                            AS state
FROM WKS_POC.G_SHEET.SHEETS__LOCATION_MASTER
WHERE "LocationType"       = 'Restaurant'
  AND "CurrentOpenStatus" = 'Open';


-- =====================================================================
-- compliance_calendar   (Magic ETL: Fiscal Calendar + "Create Compliance Proxy Date")
-- A date on or after the 19th counts toward NEXT month's compliance period.
-- e.g. Nov 19 falls in the December compliance period.
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE compliance_calendar
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = AUTO
  COMMENT = 'Each calendar day mapped to the compliance month it counts toward (19th-cutoff rule)'
AS
SELECT
  DATE           AS calendar_date,
  FRANCHISORABBR AS franchisor_abbr,
  IFF(DAY(DATE) >= 19,
      DATE_TRUNC('month', DATEADD(month, 1, DATE)),
      DATE_TRUNC('month', DATE))   AS compliance_month,
  MONTH(compliance_month)         AS compliance_period,
  YEAR(compliance_month)          AS compliance_year
FROM WKS_POC.PUBLIC.WKS_FISCAL_CALENDAR_WITH_DATE_DIMS;


-- =====================================================================
-- restaurant_days   (Magic ETL: "Loc + Cal")
-- One row per open restaurant per calendar day.
-- Inner join on FranchisorAbbr: a restaurant only gets days on the calendar
-- that belong to its franchisor.
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE restaurant_days
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = AUTO
  COMMENT = 'One row per open restaurant per calendar day'
AS
SELECT
  loc.*,
  cal.calendar_date,
  cal.compliance_month,
  cal.compliance_period,
  cal.compliance_year
FROM restaurant_locations AS loc
INNER JOIN compliance_calendar AS cal
    ON cal.franchisor_abbr = loc.franchisor_abbr;


-- =====================================================================
-- daily_form_completions   (Magic ETL: "Extract Location Code" + "Just necessary forms")
-- Pivots completed SBN inspections: one row per location per day, one column
-- per required form, holding the completion date if that form was done that day.
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE daily_form_completions
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = AUTO
  COMMENT = 'Required safety forms completed, per SBN location (location_code) per day'
AS
SELECT
  completed_date,
  location_level_1  AS brand,
  location_level_3,
  location_code,
  MAX(IFF(checklist_name = 'Monthly Employee Safety Behavior Observation Form', completed_date, NULL)) AS employee_safety_observation_date,
  MAX(IFF(checklist_name = 'Monthly Safety Committee Meeting Form',             completed_date, NULL)) AS safety_committee_meeting_date,
  MAX(IFF(checklist_name = 'Monthly Store Inspection Form',                     completed_date, NULL)) AS store_inspection_date
FROM WKS_POC.TRANSFORMATIONS.sbn_completed_inspections
GROUP BY
  completed_date,
  location_level_1,
  location_level_3,
  location_code;


-- =====================================================================
-- safety_training_by_due_date   (Magic ETL: WKS+ Progress Report + "Safety" + "Group By")
-- Required safety training for active employees.
-- Per location / series / due date: how many associates completed on time
-- (within 3 days of the due date), vs total assigned.
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE safety_training_by_due_date
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = AUTO
  COMMENT = 'WKS+ required safety training: on-time vs assigned, per location / series / due date'
AS
SELECT
  ADPLOCATIONCODE      AS adp_location_code,
  "SERIES DUE DATE"    AS series_due_date,
  "SERIES NAME"        AS series_name,
  "TRAINING PERIOD"    AS training_period,
  "TRAINING YEAR"      AS training_year,
  COUNT(DISTINCT CASE
    WHEN "EPISODE COMPLETION STATUS" = 'Completed'
     AND "FIRST COMPLETION DATE"    <= DATEADD(day, 3, "SERIES DUE DATE")
    THEN "ASSOCIATE ID"
  END)                 AS associates_on_time,
  COUNT(DISTINCT "ASSOCIATE ID")                AS associates_assigned
FROM WKS_POC.WKS_PLUS.WKS_PLUS_PROGRESS_REPORT_RAW
WHERE "TRAINING TYPE"                          = 'Safety'
  AND "POSITION STATUS - ACTIVE OR TERMINATED" = 'Active'
  AND "SERIES PRIORITY"                        = 'Required'
GROUP BY
  ADPLOCATIONCODE,
  LOCATIONDESC,       -- kept in GROUP BY to match Domo behavior; not passed to output
  "SERIES DUE DATE",
  "SERIES NAME",
  "TRAINING PERIOD",
  "TRAINING YEAR";


-- =====================================================================
-- restaurant_form_days   (Magic ETL: the location-matching rule inside "+ SBN Checklist")
-- Ties each day's form completions to a restaurant's adp_location_code.
-- Location matching rule (from the Magic ETL ON clause):
--   Krispy Kreme / Wendy's: SBN location_code matches the location's FranchisorUnit
--   Everyone else:          SBN location_code matches the location's AdpLocationCode
--
-- One row is kept per (adp_location_code, completed_date, location_level_3).
-- If the same restaurant appears under two different level-3 names on the same day
-- (two separate SBN jobs), both rows are preserved. That matches the Magic ETL,
-- which also keeps both rows and double-counts training for that day in the monthly
-- rate. Confirmed with Grace (2026-11-16).
--
-- This is kept as its own table so the join in restaurant_days_enriched is a
-- plain equality join, which lets the dynamic tables refresh incrementally.
-- (An OR in the join condition forces a full recompute each time.)
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE restaurant_form_days
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = INCREMENTAL
  COMMENT = 'Required forms completed, matched to restaurant adp_location_code per day; one row per distinct SBN level-3 entry'
AS
-- Krispy Kreme and Wendy's: match on FranchisorUnit
SELECT
  loc.adp_location_code,
  forms.completed_date,
  forms.location_level_3,
  forms.location_code,
  forms.employee_safety_observation_date,
  forms.safety_committee_meeting_date,
  forms.store_inspection_date
FROM daily_form_completions AS forms
INNER JOIN restaurant_locations AS loc
    ON loc.franchisor_unit = forms.location_code
WHERE forms.brand IN ('Krispy Kreme', 'Wendy''s')

UNION ALL

-- All other brands: match on AdpLocationCode
SELECT
  loc.adp_location_code,
  forms.completed_date,
  forms.location_level_3,
  forms.location_code,
  forms.employee_safety_observation_date,
  forms.safety_committee_meeting_date,
  forms.store_inspection_date
FROM daily_form_completions AS forms
INNER JOIN restaurant_locations AS loc
    ON loc.adp_location_code = forms.location_code
WHERE forms.brand NOT IN ('Krispy Kreme', 'Wendy''s');


-- =====================================================================
-- restaurant_days_enriched   (Magic ETL: "+ SBN Checklist" + "+ WKS+ Completion Data")
-- Each restaurant-day enriched with:
--   - the safety forms completed that day (from restaurant_form_days)
--   - the safety training due that day (from safety_training_by_due_date)
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE restaurant_days_enriched
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = INCREMENTAL
  COMMENT = 'Restaurant-days with forms completed and safety training due'
AS
SELECT
  days.*,
  forms.employee_safety_observation_date,
  forms.safety_committee_meeting_date,
  forms.store_inspection_date,
  training.series_due_date,
  training.series_name,
  training.training_period,
  training.training_year,
  training.associates_on_time,
  training.associates_assigned
FROM restaurant_days AS days
LEFT OUTER JOIN restaurant_form_days AS forms
    ON  forms.adp_location_code = days.adp_location_code
    AND forms.completed_date    = days.calendar_date
LEFT OUTER JOIN safety_training_by_due_date AS training
    ON  training.adp_location_code = days.adp_location_code
    AND training.series_due_date   = days.calendar_date;


-- =====================================================================
-- risk_compliance_report   (Magic ETL: "Group By 1" + "Add Formula")
-- One row per open restaurant per compliance month.
--
-- Forms:    'Completed' / 'Missing' + 1 / 0 — was the form done any day
--           in the compliance period?
-- Training: on-time / assigned for training in the same compliance period;
--           passes at ≥90%.
-- chargeback: $187.50 per missing form + $187.50 if training < 90% (max $750).
--             No training data = no rate = no chargeback for training.
--
-- -----------------------------------------------------------------------
-- COLUMN NAMES: aliased to match the Domo dataset exactly, so Domo reports
-- should be re-pointable at this table with zero rework (to be confirmed in
-- a Domo test). The more readable underscore names are kept as comments.
-- -----------------------------------------------------------------------
-- =====================================================================
CREATE OR REPLACE DYNAMIC TABLE risk_compliance_report
  TARGET_LAG = '1 hour'
  WAREHOUSE  = INGESTION_WH
  REFRESH_MODE = INCREMENTAL
  COMMENT = 'Chargebacks and compliance of safety forms and WKS+ safety training. Column names match the Domo dataset Risk | Compliance Report | PROD exactly.'
AS
WITH monthly AS (
  SELECT
    compliance_month,
    adp_location_code,
    location_name,
    district_area,
    franchisor_abbr,
    store_email,
    district_leader_email,
    region_leader_name,
    state,
    MAX(employee_safety_observation_date) IS NOT NULL  AS employee_safety_observation_done,
    MAX(safety_committee_meeting_date)    IS NOT NULL  AS safety_committee_meeting_done,
    MAX(store_inspection_date)            IS NOT NULL  AS store_inspection_done,
    SUM(IFF(training_period = compliance_period AND training_year = compliance_year,
            associates_on_time, 0))
    / NULLIF(
        SUM(IFF(training_period = compliance_period AND training_year = compliance_year,
                associates_assigned, 0)),
        0)                                              AS training_rate
  FROM restaurant_days_enriched
  GROUP BY
    compliance_month,
    adp_location_code,
    location_name,
    district_area,
    franchisor_abbr,
    store_email,
    district_leader_email,
    region_leader_name,
    state
)
-- Aliasing to match the Domo dataset exactly, so Domo reports should be
-- re-pointable at this table with zero rework (to be confirmed in a Domo test).
-- More readable underscore names are commented out next to each column.
SELECT
  compliance_month                                                AS "Compliance Proxy Date",        -- compliance_month
  adp_location_code                                              AS "AdpLocationCode",               -- adp_location_code
  location_name                                                  AS "LocationDesc",                  -- location_name
  district_area                                                  AS "District Leader & Area Filter", -- district_area
  franchisor_abbr                                                AS "FranchisorAbbr",                -- franchisor_abbr
  store_email                                                    AS "Email",                         -- store_email
  district_leader_email                                          AS "DL Email Address",              -- district_leader_email
  region_leader_name                                             AS "RegionLeaderName",              -- region_leader_name
  state                                                          AS "St",                            -- state
  IFF(employee_safety_observation_done, 'Completed', 'Missing')  AS "Monthly Employee Safety Behavior Observation Form Completion",  -- employee_safety_observation_status
  IFF(employee_safety_observation_done, 1, 0)                    AS "Monthly Employee Safety Behavior Observation Form Encoded",     -- employee_safety_observation_completed
  IFF(safety_committee_meeting_done,    'Completed', 'Missing')  AS "Monthly Safety Committee Meeting Form Completion",             -- safety_committee_meeting_status
  IFF(safety_committee_meeting_done,    1, 0)                    AS "Monthly Safety Committee Meeting Form Encoded",                -- safety_committee_meeting_completed
  IFF(store_inspection_done,            'Completed', 'Missing')  AS "Monthly Store Inspection Form Completion",                     -- store_inspection_status
  IFF(store_inspection_done,            1, 0)                    AS "Monthly Store Inspection Form Encoded",                        -- store_inspection_completed
  IFF(training_rate >= 0.9, 1, 0)                                AS "WKS+ Completion Encoded",   -- safety_training_passed
  training_rate::FLOAT                                           AS "WKS+ Completion",            -- safety_training_completion_rate
  IFF(ROUND(training_rate, 2) >= 0.9, 'Completed', 'Missing')   AS "WKS+ Completion Status",     -- safety_training_status
  (  IFF(employee_safety_observation_done, 0, 187.50)
   + IFF(safety_committee_meeting_done,    0, 187.50)
   + IFF(store_inspection_done,            0, 187.50)
   + IFF(ROUND(training_rate, 2) < 0.90,  187.50, 0)
  )::FLOAT                                                       AS "Chargeback"                  -- chargeback_amount
FROM monthly;

SHOW DYNAMIC TABLES IN SCHEMA;
