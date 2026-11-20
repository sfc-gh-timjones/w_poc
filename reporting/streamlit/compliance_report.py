"""
WKS Safety Compliance Reporting — Streamlit-in-Snowflake
=========================================================
Live version of the HTML compliance report artifact.
Queries WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT on every load,
so the data is always current after the 4 AM SBN ingest.

Deploy with:
    snow stage copy compliance_report.py @WKS_POC.REPORTING.STREAMLIT_STAGE --overwrite -c <connection>
    CREATE STREAMLIT WKS_POC.REPORTING.COMPLIANCE_REPORT
      ROOT_LOCATION = '@WKS_POC.REPORTING.STREAMLIT_STAGE'
      MAIN_FILE = 'compliance_report.py'
      QUERY_WAREHOUSE = INGESTION_WH;

Or run the full setup: reporting/streamlit/01_setup.sql
"""

import streamlit as st
import pandas as pd
from snowflake.snowpark.context import get_active_session

# ── Page config ────────────────────────────────────────────────────────────
st.set_page_config(
    page_title="Safety Compliance Reporting",
    layout="wide",
    initial_sidebar_state="collapsed",
)

# ── Shared styles ──────────────────────────────────────────────────────────
st.markdown("""
<style>
  /* Page body */
  [data-testid="stAppViewContainer"] > .main { background: #f0f4f8; }
  .block-container { max-width: 1200px; padding: 1.5rem 2rem; }

  /* Page header */
  .page-title   { font-size: 26px; font-weight: 700; color: #1b3a5c; margin-bottom: 2px; }
  .page-sub     { font-size: 13px; color: #64748b; margin-bottom: 20px; }

  /* Filter panel */
  .filter-panel { background: #dce8f5; border-radius: 8px; padding: 16px 20px 12px; margin-bottom: 16px; }
  .filter-label { font-size: 11px; font-weight: 700; text-transform: uppercase;
                  letter-spacing: 0.5px; color: #1b3a5c; margin-bottom: 2px; }

  /* KPI cards */
  .kpi-row { display: flex; gap: 12px; margin-bottom: 16px; }
  .kpi-card { flex: 1; background: #fff; border: 1px solid #cbd5e1;
              border-top: 3px solid #1b3a5c; border-radius: 6px;
              padding: 12px 16px; text-align: center; }
  .kpi-lbl  { font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px;
              color: #64748b; margin-bottom: 4px; }
  .kpi-val  { font-size: 22px; font-weight: 700; color: #1b3a5c; }
  .kpi-sub  { font-size: 11px; color: #94a3b8; margin-top: 2px; }

  /* Report subtitle */
  .report-title { font-size: 14px; font-weight: 500; color: #1e293b; margin-bottom: 8px; }

  /* Compliance table */
  .compliance-wrap { overflow-x: auto; border-radius: 6px; border: 1px solid #cbd5e1; }
  .compliance-table { border-collapse: collapse; width: 100%; min-width: 860px;
                      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
                      font-size: 12px; }
  .compliance-table thead th {
    background: #1b3a5c; color: #fff; padding: 10px 8px;
    font-size: 12px; font-weight: 600; text-align: center;
    border-right: 1px solid rgba(255,255,255,0.15); line-height: 1.3;
    vertical-align: middle;
  }
  .compliance-table thead th:first-child,
  .compliance-table thead th:nth-child(2) { text-align: left; }
  .compliance-table thead th:last-child    { border-right: none; }

  .compliance-table tbody tr { border-bottom: 1px solid #cbd5e1; }
  .compliance-table tbody tr:nth-child(even) td { background: #f8fafc; }
  .compliance-table tbody td {
    padding: 7px 8px; vertical-align: middle; text-align: center;
    border-right: 1px solid #cbd5e1;
  }
  .compliance-table tbody td:last-child  { border-right: none; }
  .compliance-table tbody td:first-child,
  .compliance-table tbody td:nth-child(2) { text-align: left; }

  /* Status cells */
  .completed { background: #198754 !important; color: #fff; font-weight: 600; }
  .missing   { background: #c0392b !important; color: #fff; font-weight: 600; }

  /* District rows */
  .district-sub td  { background: #2a5b8a !important; color: #fff;
                      font-weight: 600; border-right: 1px solid rgba(255,255,255,0.2); }
  .district-sub td:last-child { border-right: none; }
  .grand-total td   { background: #0f2640 !important; color: #fff;
                      font-weight: 700; border-right: 1px solid rgba(255,255,255,0.15); }
  .grand-total td:last-child  { border-right: none; }
  .cb-bad  { color: #c0392b; font-weight: 700; }
  .cb-good { color: #198754; font-weight: 600; }
</style>
""", unsafe_allow_html=True)

# ── Data loading ───────────────────────────────────────────────────────────
BRAND_NAMES = {"DEN": "Denny's", "EPL": "El Pollo Loco", "KK": "Krispy Kreme", "WEN": "Wendy's"}

@st.cache_data(ttl=300, show_spinner="Loading compliance data…")
def load_compliance_data() -> pd.DataFrame:
    session = get_active_session()
    # Snowpark returns uppercase column names; lowercase them for attribute access
    df = session.sql("""
        SELECT
          TO_CHAR("Compliance Proxy Date", 'YYYY-MM-DD')                      AS compliance_month,
          "District Leader & Area Filter"                                      AS district,
          "LocationDesc"                                                       AS location,
          "FranchisorAbbr"                                                     AS franchisor,
          "Monthly Employee Safety Behavior Observation Form Completion"       AS form_emp_obs,
          "Monthly Safety Committee Meeting Form Completion"                   AS form_safety_mtg,
          "Monthly Store Inspection Form Completion"                           AS form_store_insp,
          CASE WHEN "WKS+ Completion" IS NULL THEN NULL
               ELSE ROUND("WKS+ Completion"*100, 1) END                       AS wks_pct,
          "WKS+ Completion Encoded"                                            AS wks_enc,
          "Monthly Employee Safety Behavior Observation Form Encoded"          AS form_emp_obs_enc,
          "Monthly Safety Committee Meeting Form Encoded"                      AS form_safety_mtg_enc,
          "Monthly Store Inspection Form Encoded"                              AS form_store_insp_enc,
          "Chargeback"                                                         AS chargeback
        FROM WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT
        WHERE "FranchisorAbbr" <> 'CWD'
          AND "Compliance Proxy Date" <= CURRENT_DATE()
        ORDER BY compliance_month, district, location
    """).to_pandas()
    df.columns = [c.lower() for c in df.columns]
    return df

# ── Helpers ────────────────────────────────────────────────────────────────
MONTH_NAMES = ["January","February","March","April","May","June",
               "July","August","September","October","November","December"]

def fmt_month(iso: str) -> str:
    y, m, _ = iso.split("-")
    return f"{MONTH_NAMES[int(m)-1]} {y}"

def fmt_cur(v) -> str:
    return f"${float(v):,.2f}"

def total_pct(row) -> int:
    return round((int(row.form_emp_obs_enc) + int(row.form_safety_mtg_enc) +
                  int(row.form_store_insp_enc) + int(row.wks_enc)) / 4 * 100)

def status_cell(val: str) -> str:
    cls = "completed" if val == "Completed" else "missing"
    return f'<td class="{cls}">{val}</td>'

def wks_cell(wp) -> str:
    if wp is None or (isinstance(wp, float) and pd.isna(wp)):
        return "<td>&#8212;</td>"
    pct = round(float(wp))
    cls = "completed" if pct >= 90 else "missing"
    return f'<td class="{cls}">{pct}%</td>'

# ── Build table HTML ───────────────────────────────────────────────────────
def build_table(df: pd.DataFrame) -> str:
    if df.empty:
        return '<tr><td colspan="8" style="text-align:center;padding:32px;color:#64748b;font-style:italic">No locations match the selected filters.</td></tr>'

    rows_html = ""
    districts = df["district"].unique().tolist()
    grand_cb = grand_wp = grand_tp = grand_count = 0

    for d in sorted(districts):
        d_rows = df[df["district"] == d].sort_values("location")
        dist_cb = dist_wp = dist_tp = 0

        for i, (_, row) in enumerate(d_rows.iterrows()):
            tp = total_pct(row)
            dist_cb += float(row.chargeback)
            if row.wks_pct is not None and not pd.isna(row.wks_pct):
                dist_wp += float(row.wks_pct)
            dist_tp += tp
            cb_cls = "cb-bad" if float(row.chargeback) > 0 else "cb-good"
            d_cell = f"<td>{d}</td>" if i == 0 else "<td></td>"
            rows_html += (
                f"<tr>{d_cell}<td>{row.location}</td>"
                f"{status_cell(row.form_emp_obs)}{status_cell(row.form_safety_mtg)}{status_cell(row.form_store_insp)}"
                f"{wks_cell(row.wks_pct)}"
                f"<td>{tp}%</td>"
                f'<td class="{cb_cls}">{fmt_cur(row.chargeback)}</td></tr>'
            )

        n = len(d_rows)
        avg_tp = round(dist_tp / n) if n else 0
        wp_str = f"{round(dist_wp)}%" if dist_wp > 0 else "&#8212;"
        rows_html += (
            f'<tr class="district-sub">'
            f'<td colspan="2">{d} TOTAL</td>'
            f'<td></td><td></td><td></td>'
            f'<td style="text-align:center">{wp_str}</td>'
            f'<td style="text-align:center">{avg_tp}%</td>'
            f'<td style="text-align:right">{fmt_cur(dist_cb)}</td></tr>'
        )
        grand_cb += dist_cb; grand_wp += dist_wp; grand_tp += dist_tp; grand_count += n

    grand_avg = round(grand_tp / grand_count) if grand_count else 0
    rows_html += (
        f'<tr class="grand-total">'
        f'<td colspan="2">GRAND TOTAL</td>'
        f'<td></td><td></td><td></td>'
        f'<td style="text-align:center">&#8212;</td>'
        f'<td style="text-align:center">{grand_avg}%</td>'
        f'<td style="text-align:right">{fmt_cur(grand_cb)}</td></tr>'
    )
    return rows_html

# ── Main ───────────────────────────────────────────────────────────────────
df_all = load_compliance_data()

# ── Page header ────────────────────────────────────────────────────────────
st.markdown('<div class="page-title">Safety Compliance Reporting</div>', unsafe_allow_html=True)
st.markdown('<div class="page-sub">Risk | Compliance Report | WKS Restaurant Group — Powered by Snowflake</div>', unsafe_allow_html=True)

# ── Filter panel ───────────────────────────────────────────────────────────
st.markdown('<div class="filter-panel">', unsafe_allow_html=True)

# Period filter — full width
months = sorted(df_all["compliance_month"].unique(), reverse=True)
month_labels = {m: fmt_month(m) + (" (Current Period)" if i == 0 else "") for i, m in enumerate(months)}
selected_period = st.selectbox(
    "Select Compliance Period",
    options=months,
    format_func=lambda m: month_labels[m],
)

# Brand, District, Location — 3 columns
c1, c2, c3 = st.columns(3)
df_period = df_all[df_all["compliance_month"] == selected_period]

with c1:
    brands = sorted(df_period["franchisor"].unique())
    brand_opts = [""] + brands
    selected_brand = st.selectbox(
        "Brand Filter",
        options=brand_opts,
        format_func=lambda b: "Select (All Brands)" if b == "" else BRAND_NAMES.get(b, b),
    )

df_b = df_period if selected_brand == "" else df_period[df_period["franchisor"] == selected_brand]

with c2:
    districts = sorted(df_b["district"].unique())
    dist_opts = [""] + districts
    selected_district = st.selectbox(
        "District Filter",
        options=dist_opts,
        format_func=lambda d: "Select (All Districts)" if d == "" else d,
    )

df_bd = df_b if selected_district == "" else df_b[df_b["district"] == selected_district]

with c3:
    locations = sorted(df_bd["location"].unique())
    loc_opts = [""] + locations
    selected_location = st.selectbox(
        "Location Filter",
        options=loc_opts,
        format_func=lambda l: "Select (All Locations)" if l == "" else l,
    )

st.markdown("</div>", unsafe_allow_html=True)

# ── Apply all filters ──────────────────────────────────────────────────────
df_filtered = df_bd if selected_location == "" else df_bd[df_bd["location"] == selected_location]

# ── KPI strip ──────────────────────────────────────────────────────────────
n_locs = len(df_filtered)
fully_compliant = sum(1 for _, r in df_filtered.iterrows() if total_pct(r) == 100)
pct_compliant = round(fully_compliant / n_locs * 100) if n_locs else 0
total_chargeback = df_filtered["chargeback"].sum()
brand_suffix = f" | Brand: {BRAND_NAMES.get(selected_brand, selected_brand)}" if selected_brand else ""

st.markdown(f"""
<div class="kpi-row">
  <div class="kpi-card"><div class="kpi-lbl">Locations Shown</div><div class="kpi-val">{n_locs:,}</div></div>
  <div class="kpi-card"><div class="kpi-lbl">Fully Compliant</div><div class="kpi-val">{pct_compliant}%</div><div class="kpi-sub">all 4 items complete</div></div>
  <div class="kpi-card"><div class="kpi-lbl">Total Chargeback</div><div class="kpi-val">{fmt_cur(total_chargeback)}</div></div>
</div>
""", unsafe_allow_html=True)

# ── Report subtitle ────────────────────────────────────────────────────────
st.markdown(
    f'<div class="report-title">Compliance Report | (Excludes CWD){brand_suffix} | Compliance Period: {fmt_month(selected_period)}</div>',
    unsafe_allow_html=True,
)

# ── Compliance table ───────────────────────────────────────────────────────
rows_html = build_table(df_filtered)

table_html = f"""
<div class="compliance-wrap">
<table class="compliance-table">
  <thead>
    <tr>
      <th style="min-width:140px">District Leader &amp; Area Filter</th>
      <th style="min-width:160px">LocationDesc</th>
      <th style="min-width:100px">Monthly Employee Safety Behavior Observation Form Completion</th>
      <th style="min-width:100px">Monthly Safety Committee Meeting Form Completion</th>
      <th style="min-width:100px">Monthly Store Inspection Form Completion</th>
      <th style="min-width:80px">WKS+<br>Completion Status</th>
      <th style="min-width:60px">Total %</th>
      <th style="min-width:80px">Chargeback</th>
    </tr>
  </thead>
  <tbody>{rows_html}</tbody>
</table>
</div>
"""
st.markdown(table_html, unsafe_allow_html=True)
