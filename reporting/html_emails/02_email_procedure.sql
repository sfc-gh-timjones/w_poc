-- =====================================================================
-- STEP 2 of 3: Python stored procedure that builds an HTML compliance
-- email and sends it via SYSTEM$SEND_EMAIL.
--
-- Run as ACCOUNTADMIN after step 1 (01_setup.sql).
--
-- The procedure accepts:
--   AREA_FILTER  VARCHAR  — a SQL LIKE pattern that matches the
--                           "District Leader & Area Filter" column.
--                           Examples: '% | Area 1'  '% | Area 2'
--   RECIPIENT    VARCHAR  — email address (must be in ALLOWED_RECIPIENTS
--                           of WKS_COMPLIANCE_EMAIL_INT)
--
-- Call to test:
--   CALL WKS_POC.REPORTING.SEND_COMPLIANCE_EMAIL('% | Area 1', 't.jones@snowflake.com');
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE DATABASE WKS_POC;
USE SCHEMA REPORTING;
USE WAREHOUSE INGESTION_WH;

CREATE OR REPLACE PROCEDURE WKS_POC.REPORTING.SEND_COMPLIANCE_EMAIL(
  DISTRICT_FILTER  VARCHAR,
  RECIPIENT        VARCHAR
)
  RETURNS VARCHAR
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.12'
  PACKAGES       = ('snowflake-snowpark-python')
  HANDLER        = 'run'
AS
$$
def run(session, district_filter: str, recipient: str) -> str:
    # -----------------------------------------------------------------
    # 1. Most recent completed compliance period (<= today)
    # -----------------------------------------------------------------
    latest_row = session.sql("""
        SELECT MAX("Compliance Proxy Date") AS cp
        FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
        WHERE "Compliance Proxy Date" <= CURRENT_DATE()
    """).collect()
    latest = latest_row[0]["CP"]
    if latest is None:
        return "No past compliance periods found -- email not sent."

    month_label = latest.strftime("%B %Y")
    district_label = district_filter

    # -----------------------------------------------------------------
    # 2. Query filtered data
    # -----------------------------------------------------------------
    df = session.sql(f"""
        SELECT
          "District Leader & Area Filter"                                      AS district,
          "LocationDesc"                                                       AS location,
          "Monthly Employee Safety Behavior Observation Form Completion"       AS emp_obs,
          "Monthly Safety Committee Meeting Form Completion"                   AS safety_mtg,
          "Monthly Store Inspection Form Completion"                           AS store_insp,
          CASE WHEN "WKS+ Completion" IS NULL THEN '—'
               ELSE ROUND("WKS+ Completion" * 100, 0)::VARCHAR || '%' END     AS wks_pct,
          CASE WHEN "WKS+ Completion" IS NULL THEN 0
               ELSE "WKS+ Completion Encoded" END                             AS wks_enc,
          "Monthly Employee Safety Behavior Observation Form Encoded"          AS n1,
          "Monthly Safety Committee Meeting Form Encoded"                      AS n2,
          "Monthly Store Inspection Form Encoded"                              AS n3,
          "Chargeback"                                                         AS chargeback
        FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
        WHERE "Compliance Proxy Date" = '{latest}'
          AND "District Leader & Area Filter" = '{district_filter}'
        ORDER BY district, location
    """).to_pandas()

    if df.empty:
        return f"No data for district '{district_filter}' in {month_label}."

    # -----------------------------------------------------------------
    # 3. Build HTML email (inline styles for email-client compatibility)
    # -----------------------------------------------------------------
    GREEN  = "#198754"
    RED    = "#c0392b"
    NAVY   = "#1b3a5c"
    SUB_BG = "#2a5b8a"
    WHITE  = "#ffffff"
    LIGHT  = "#f8fafc"

    def status_cell(val):
        bg = GREEN if val == "Completed" else RED
        return f'<td style="background:{bg};color:#fff;font-weight:600;text-align:center;padding:6px 8px;border:1px solid #ddd">{val}</td>'

    def money(v):
        return f"${float(v):,.2f}"

    rows_html = ""
    prev_district = None
    dist_cb = 0.0; dist_wp_sum = 0.0; dist_tp_sum = 0; dist_count = 0

    def subtotal_row(d, cb, wp_sum, tp_sum, count):
        avg_tp = round(tp_sum / count) if count else 0
        wp_str = f"{round(wp_sum)}%" if wp_sum > 0 else "—"
        return (
            f'<tr style="background:{SUB_BG};color:{WHITE};font-weight:600">'
            f'<td colspan="2" style="padding:6px 10px;border:1px solid rgba(255,255,255,0.2)">{d} TOTAL</td>'
            f'<td style="border:1px solid rgba(255,255,255,0.2)"></td>'
            f'<td style="border:1px solid rgba(255,255,255,0.2)"></td>'
            f'<td style="border:1px solid rgba(255,255,255,0.2)"></td>'
            f'<td style="text-align:center;border:1px solid rgba(255,255,255,0.2)">{wp_str}</td>'
            f'<td style="text-align:center;border:1px solid rgba(255,255,255,0.2)">{avg_tp}%</td>'
            f'<td style="text-align:right;font-weight:700;padding:6px 8px;border:1px solid rgba(255,255,255,0.2)">{money(cb)}</td>'
            f'</tr>'
        )

    pending_subtotals = []
    grand_cb = 0.0; grand_wp = 0.0; grand_tp = 0; grand_count = 0

    rows = list(df.itertuples(index=False))
    for idx, r in enumerate(rows):
        is_first_in_district = (r.district != prev_district)
        if is_first_in_district and prev_district is not None:
            rows_html += subtotal_row(prev_district, dist_cb, dist_wp_sum, dist_tp_sum, dist_count)
            dist_cb = dist_wp_sum = dist_tp_sum = dist_count = 0

        tp = round((int(r.n1) + int(r.n2) + int(r.n3) + int(r.wks_enc)) / 4 * 100)
        dist_cb      += float(r.chargeback)
        dist_wp_sum  += (float(r.wks_pct.replace('%','').replace('—','0')))
        dist_tp_sum  += tp
        dist_count   += 1
        grand_cb     += float(r.chargeback)
        grand_wp     += dist_wp_sum
        grand_tp     += tp
        grand_count  += 1

        bg = WHITE if idx % 2 == 0 else LIGHT
        d_cell = r.district if is_first_in_district else ""
        cb_color = RED if float(r.chargeback) > 0 else GREEN
        rows_html += (
            f'<tr style="background:{bg}">'
            f'<td style="padding:6px 8px;border:1px solid #ddd">{d_cell}</td>'
            f'<td style="padding:6px 8px;border:1px solid #ddd">{r.location}</td>'
            + status_cell(r.emp_obs) + status_cell(r.safety_mtg) + status_cell(r.store_insp) +
            f'<td style="text-align:center;padding:6px 8px;border:1px solid #ddd">{r.wks_pct}</td>'
            f'<td style="text-align:center;padding:6px 8px;border:1px solid #ddd">{tp}%</td>'
            f'<td style="text-align:right;font-weight:700;color:{cb_color};padding:6px 8px;border:1px solid #ddd">{money(r.chargeback)}</td>'
            f'</tr>'
        )
        prev_district = r.district

    # Last district subtotal
    if prev_district:
        rows_html += subtotal_row(prev_district, dist_cb, dist_wp_sum, dist_tp_sum, dist_count)

    # Grand total
    grand_avg_tp = round(grand_tp / grand_count) if grand_count else 0
    rows_html += (
        f'<tr style="background:#0f2640;color:{WHITE};font-weight:700">'
        f'<td colspan="2" style="padding:8px 10px;border:1px solid rgba(255,255,255,0.15)">GRAND TOTAL</td>'
        f'<td style="border:1px solid rgba(255,255,255,0.15)"></td>'
        f'<td style="border:1px solid rgba(255,255,255,0.15)"></td>'
        f'<td style="border:1px solid rgba(255,255,255,0.15)"></td>'
        f'<td style="text-align:center;border:1px solid rgba(255,255,255,0.15)">—</td>'
        f'<td style="text-align:center;border:1px solid rgba(255,255,255,0.15)">{grand_avg_tp}%</td>'
        f'<td style="text-align:right;padding:8px;border:1px solid rgba(255,255,255,0.15)">{money(grand_cb)}</td>'
        f'</tr>'
    )

    th = lambda t: f'<th style="background:{NAVY};color:{WHITE};padding:9px 8px;text-align:center;font-size:12px;border:1px solid rgba(255,255,255,0.2);line-height:1.3">{t}</th>'

    body = f"""<!DOCTYPE html>
<html><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:0;padding:16px;background:#f0f4f8;color:#1e293b">
  <div style="max-width:900px;margin:0 auto;background:#fff;border-radius:8px;padding:24px;box-shadow:0 2px 8px rgba(0,0,0,.08)">
    <h1 style="font-size:20px;font-weight:700;color:#1b3a5c;margin:0 0 4px">Safety Compliance Reporting</h1>
    <p style="margin:0 0 20px;color:#64748b;font-size:13px">Risk | Compliance Report | WKS Restaurant Group — {district_label} — {month_label} — Powered by Snowflake</p>

    <table style="border-collapse:collapse;width:100%;font-size:12px">
      <thead>
        <tr>
          {th('District Leader & Area Filter')}
          {th('LocationDesc')}
          {th('Monthly Employee Safety Behavior Observation Form Completion')}
          {th('Monthly Safety Committee Meeting Form Completion')}
          {th('Monthly Store Inspection Form Completion')}
          {th('WKS+<br>Completion Status')}
          {th('Total %')}
          {th('Chargeback')}
        </tr>
      </thead>
      <tbody>{rows_html}</tbody>
    </table>

    <p style="margin:20px 0 0;font-size:11px;color:#94a3b8">
      Data source: WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT •
      Compliance period: {month_label} •
      Sent by Snowflake Task
    </p>
  </div>
</body></html>"""

    # -----------------------------------------------------------------
    # 4. Send email
    # -----------------------------------------------------------------
    subject = f"WKS Compliance Report — {district_label} — {month_label}"
    session.call("SYSTEM$SEND_EMAIL",
                 "WKS_COMPLIANCE_EMAIL_INT",
                 recipient,
                 subject,
                 body,
                 "text/html")
    return f"Sent '{subject}' to {recipient} ({len(df)} locations)"
$$;
