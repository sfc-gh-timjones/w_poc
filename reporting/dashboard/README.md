# WKS Compliance Dashboard

A Snowflake Dashboard 2.0 that replicates the compliance report as an interactive multi-tile dashboard. Viewers can click districts in the chargeback bar chart to filter the whole dashboard, or ask follow-up questions in CoWork.

## What is a Snowflake Dashboard?

Snowflake Dashboards 2.0 are SQL-backed interactive dashboards built in Snowsight Workspaces and stored as `.dash` files. Unlike the HTML report (static snapshot) or the Streamlit app (Python app), they:

- Run every tile query live against Snowflake at view time (caller's rights)
- Support chart actions: click a bar to filter every other tile
- Support conversational follow-ups in CoWork ("why is District 5 above average?")
- Are shared as artifacts via RBAC, same as HTML reports
- Are built with CoCo's `/dashboard` command or manually in Snowsight

## Quickest path: build with CoCo in Snowsight

1. Open **Snowsight → Workspaces** and create or open your workspace.
2. Click **Create → Dashboard**, or type `/dashboard` in the CoCo chat panel.
3. Paste this prompt:

```
Build a WKS Safety Compliance dashboard using WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT.
Exclude FranchisorAbbr = 'CWD'. Only show compliance periods <= CURRENT_DATE().

Include:
- 3 scorecard tiles: "Total Locations", "Fully Compliant %" (all 4 items complete), "Total Chargeback ($)"
- 1 horizontal bar chart: Chargeback by District, sorted descending
- 1 grouped bar chart: Fully Compliant vs Not Compliant locations, by Brand (DEN/EPL/KK/WEN)
- 1 line chart: Fully Compliant % trend over the last 12 months
- 1 table: full compliance detail (District, Location, 3 form statuses, WKS+ %, Total %, Chargeback)

Add 3 filters:
- Compliance Period: single-select date, default = most recent past month
- Brand Filter: multi-select on FranchisorAbbr
- District Filter: multi-select on "District Leader & Area Filter"

Connect the bar chart on District so clicking a bar filters the other tiles.
```

CoCo will generate the `.dash` file, write the tile SQL, and open the dashboard for review.

## Manual path: use the tile SQL in this folder

If you prefer to build manually (or want to review the SQL before pasting into CoCo):

1. Open **Snowsight → Workspaces → Create → Dashboard**.
2. For each tile in `01_tile_queries.sql`, click **+ Add tile → Chart** (or **Table**), paste the SQL, and choose the chart type noted in the comment.
3. Add filters using the SQL at the bottom of `01_tile_queries.sql`.

### Tiles

| Tile | File section | Chart type | Key fields |
|---|---|---|---|
| Scorecard: Total Locations | TILE 1 | Scorecard | LOCATION_COUNT |
| Scorecard: Fully Compliant % | TILE 2 | Scorecard | FULLY_COMPLIANT_PCT |
| Scorecard: Total Chargeback | TILE 3 | Scorecard | TOTAL_CHARGEBACK |
| Chargeback by District | TILE 4 | Horizontal bar | X: DISTRICT, Y: TOTAL_CHARGEBACK |
| Compliance by Brand | TILE 5 | Grouped bar | X: BRAND, Y: FULLY_COMPLIANT / NOT_COMPLIANT |
| Full detail table | TILE 6 | Table | All columns |
| Compliance trend | TILE 7 | Line | X: COMPLIANCE_MONTH, Y: FULLY_COMPLIANT_PCT |

### Filters (define in the dashboard filter panel)

| Filter name | Type | Source | Default |
|---|---|---|---|
| `compliance_period` | timestamp / single-select | Column: `"Compliance Proxy Date"` | Most recent past month |
| `brand` | string / multi-select | Static: DEN, EPL, KK, WEN | All |
| `district` | string / multi-select | Column: `"District Leader & Area Filter"` | All |

Add `{{ filter('compliance_period') }}`, `{{ filter('brand') }}`, and `{{ filter('district') }}` placeholders to the WHERE clause of each tile SQL.

### Suggested chart action

After adding tiles: select the **Chargeback by District** bar chart → **Add chart action → Filter → Target: all other tiles**. Clicking a district bar then filters the whole dashboard to that district.

## Share the dashboard

1. In Workspaces, open the `.dash` file.
2. Click **Share → Create artifact**.
3. Add roles or users under **Grant access**.
4. Copy the shareable link.

The link opens in CoWork, where viewers can also ask follow-up questions on any tile.

## Notes

- **Warehouse:** tile queries run on `INGESTION_WH` (the viewer's active warehouse at open time). No compute pool needed.
- **WKS_POC hardcoded:** all tile SQL uses `WKS_POC.TRANSFORMATIONS.RISK_COMPLIANCE_REPORT`. If the database differs, find-replace `WKS_POC` in `01_tile_queries.sql`.
- **Data freshness:** queries run live. The dashboard is always current after the 4 AM SBN ingest, with no publish step.
