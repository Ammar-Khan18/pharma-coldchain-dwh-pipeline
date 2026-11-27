# Power BI build guide — `sdi_business.pbix` (Milestone 2)

A step-by-step for building the Sales & Demand Intelligence business dashboard in
**Power BI Desktop (Windows)**, reading the Phase 1 mart from Postgres (running in
WSL). No prior Power BI experience assumed — follow it top to bottom.

The report has **3 pages** plus a small **"Data as of"** card on every page:

| Page | Title | Reads view(s) |
|------|-------|---------------|
| 1 | Sales & Channel Performance | `mart.v_kpi_latest_month`, `mart.v_channel_month` |
| 2 | Hospital Forecast vs Actual & Unfulfilled Demand | `mart.v_hospital_forecast_month` |
| 3 | Fast vs Slow Movers | `mart.v_medicine_movement` |
| all | "Data as of" card | `mart.v_refresh_status` |

All five views live in Postgres schema `mart`, are read-only to the `bi_reader`
login, and are defined in [`sql/postgres/07_bi_views.sql`](../sql/postgres/07_bi_views.sql).
They are rebuilt automatically every time the pipeline republishes the mart, so the
dashboard just needs a **Refresh**.

---

## 0. Before you start

- **Power BI Desktop** installed on Windows (free from the Microsoft Store).
- The pipeline's Postgres must be running in WSL and the mart published
  (`serving/publish_mart.py` has run at least once).
- Credentials (read-only): user `bi_reader`, password `bi_pass`, database `ida_staging`.

### Find the WSL IP address

Power BI runs on Windows; Postgres runs inside WSL, which has its own IP. In a WSL
terminal run:

```bash
hostname -I
```

Take the **first** address it prints (e.g. `172.19.174.182`). Call it `WSL_IP`
below. This can change when you reboot WSL — if Power BI can't connect later,
re-run `hostname -I` and update the connection (Transform data → Data source settings).

> Tip: confirm the login works before opening Power BI:
> ```bash
> PGPASSWORD=bi_pass psql -h localhost -U bi_reader -d ida_staging -c "select * from mart.v_refresh_status;"
> ```

---

## 1. Connect Power BI to Postgres

1. Open Power BI Desktop → **Home** → **Get data** → **More…** → search **PostgreSQL database** → **Connect**.
2. In the dialog:
   - **Server:** `WSL_IP` (the address from `hostname -I`, e.g. `172.19.174.182`)
   - **Database:** `ida_staging`
   - **Data Connectivity mode:** **Import** (select it — *not* DirectQuery)
   - Leave *Advanced options* empty → **OK**
3. Credentials screen → **Database** tab on the left:
   - **User name:** `bi_reader`
   - **Password:** `bi_pass`
   - **Encrypt connections:** **turn OFF** (uncheck it). The local Postgres has no
     TLS cert, so leaving this on makes the connection fail.
   - **Connect**. If it warns the connection is unencrypted, choose **OK / proceed**.
4. The **Navigator** opens. Expand **mart** and tick only these five views:
   - `v_kpi_latest_month`
   - `v_channel_month`
   - `v_hospital_forecast_month`
   - `v_medicine_movement`
   - `v_refresh_status`
5. Click **Load** (not *Transform Data* — the views are already clean).

You now have five tables in the **Data** pane on the right.

> If the dropped/renamed-column warning ever appears after a schema change, click
> **Refresh** on the ribbon; the views keep the same column names across refreshes.

---

## 2. One-time model housekeeping

These make months sort correctly and numbers format nicely. Do them once.

### 2a. Make month labels sort chronologically

`month_label` ("Mar 2026") otherwise sorts alphabetically. For **each** of
`v_channel_month`, `v_hospital_forecast_month`, `v_medicine_movement`:

1. In the **Data** pane, click the `month_label` column.
2. Ribbon → **Column tools** → **Sort by column** → pick **`month_key`**.

### 2b. (Optional) hide helper columns

Right-click `month_key`, `month_number`, `month_start`, `year` → **Hide** so the
field list stays tidy. They still work for sorting/measures while hidden.

### 2c. No relationships needed

Each page's visuals and that page's slicers all read from **one** view, so Power BI
filters them together automatically. You do **not** need to create relationships for
the base build. (Advanced, optional: to make one month slicer drive all three pages,
create a small Date table and relate each view's `month_key` to it — skip this for now.)

---

## 3. DAX measures — paste these first

Create measures before building visuals. For each: in the **Data** pane right-click
the listed table → **New measure**, then paste the code (replace the default text),
press **Enter**. The comment line is optional.

### On `v_channel_month` (Page 1)

```DAX
Revenue = SUM(v_channel_month[revenue])
```
```DAX
Cost = SUM(v_channel_month[cost])
```
```DAX
Gross Margin = SUM(v_channel_month[gross_margin])
```
```DAX
-- SUM/SUM, never the average of per-row percentages
Gross Margin % = DIVIDE([Gross Margin], [Revenue])
```
Format `Gross Margin %` as Percentage: select the measure → **Measure tools** →
**Format: Percentage**, 1 decimal. Format `Revenue`/`Cost`/`Gross Margin` as whole
number with thousands separator.

### On `v_kpi_latest_month` (Page 1 cards — always the latest month)

This view is a single row (latest month vs previous month), so `SUM` just returns
the value. Deltas are pre-computed in the view; these measures format them for cards.

```DAX
Latest Revenue = SUM(v_kpi_latest_month[revenue])
```
```DAX
Latest Units = SUM(v_kpi_latest_month[units])
```
```DAX
Latest Gross Margin % = SUM(v_kpi_latest_month[gross_margin_pct])
```
```DAX
Latest Unfulfilled Demand = SUM(v_kpi_latest_month[unfulfilled_demand])
```
```DAX
-- month-over-month change for the "vs last month" line under each card
Revenue MoM % = SUM(v_kpi_latest_month[revenue_mom_pct])
```
```DAX
Units MoM % = SUM(v_kpi_latest_month[units_mom_pct])
```
```DAX
-- percentage POINTS change (margin this month minus margin last month)
Gross Margin pp Change = SUM(v_kpi_latest_month[gross_margin_pct_delta])
```
```DAX
Unfulfilled Demand MoM % = SUM(v_kpi_latest_month[unfulfilled_demand_mom_pct])
```
Format the three `… MoM %` measures and `Gross Margin pp Change` as Percentage;
`Latest Gross Margin %` as Percentage; the rest as whole number.

### On `v_hospital_forecast_month` (Page 2)

```DAX
Forecast Demand = SUM(v_hospital_forecast_month[forecast_demand])
```
```DAX
Actual Consumed = SUM(v_hospital_forecast_month[actual_consumed])
```
```DAX
-- recompute the ratio from the totals, do not average the row ratios
Actual vs Forecast % = DIVIDE([Actual Consumed], [Forecast Demand])
```
```DAX
Unfulfilled Demand = SUM(v_hospital_forecast_month[unfulfilled_demand])
```
Format `Actual vs Forecast %` as Percentage (0 decimals is fine).

### On `v_medicine_movement` (Page 3)

```DAX
Units Sold = SUM(v_medicine_movement[units_sold])
```

### On `v_refresh_status` (every page's "Data as of" card)

```DAX
Data As Of =
"Data as of " & SELECTEDVALUE(v_refresh_status[latest_data_month])
  & "  •  refreshed " & FORMAT(MAX(v_refresh_status[last_refresh_at]), "yyyy-mm-dd HH:mm")
```
```DAX
-- optional second line proving the data grew after a refresh
Fact Rows =
"Sales rows: " & FORMAT(MAX(v_refresh_status[pharmacy_sales_rows]), "#,0")
  & "   Demand rows: " & FORMAT(MAX(v_refresh_status[hospital_demand_rows]), "#,0")
```

---

## 4. The "Data as of" card (put on every page)

1. Insert a **Card (new)** visual, small, top-right corner.
2. Drag the measure **`Data As Of`** into its field well.
3. (Optional) add a second small card for **`Fact Rows`**.
4. Build it once, then **copy** it (Ctrl+C) and **paste** (Ctrl+V) onto pages 2 and 3
   so all three pages carry the same refresh stamp.

---

## 5. Page 1 — Sales & Channel Performance

Rename the page tab (double-click) to **Sales & Channel Performance**.

### 5a. KPI cards (top row) — from `v_kpi_latest_month`

Add four **Card (new)** visuals across the top. For each, drop the main measure in,
then add the matching MoM measure as a second field (or a second small card beneath):

| Card | Main measure | "vs last month" measure |
|------|--------------|--------------------------|
| Revenue | `Latest Revenue` | `Revenue MoM %` |
| Units Sold | `Latest Units` | `Units MoM %` |
| Gross Margin % | `Latest Gross Margin %` | `Gross Margin pp Change` |
| Unfulfilled Demand | `Latest Unfulfilled Demand` | `Unfulfilled Demand MoM %` |

These cards intentionally always show the **latest month** and ignore the month
slicer — that is what makes them "this month vs last month" headline numbers.

### 5b. Revenue & margin by channel over time — from `v_channel_month`

1. **Line and clustered column chart** (or **Clustered column chart**).
   - **X-axis:** `month_label`
   - **Column values:** `Revenue`
   - **Line values (secondary axis):** `Gross Margin %`
   - **Legend:** `channel`
2. **Clustered bar chart** — revenue by channel:
   - **Y-axis:** `channel`
   - **X-axis:** `Revenue`
3. **Table** — the margin detail:
   - **Columns:** `month_label`, `channel`, `Revenue`, `Cost`, `Gross Margin`, `Gross Margin %`

### 5c. Slicers on Page 1

Add two **Slicer** visuals (both from `v_channel_month`, so they filter 5b's visuals):

- **Month slicer:** field `month_label` (set slicer to Dropdown).
- **Channel slicer:** field `channel`.

---

## 6. Page 2 — Hospital Forecast vs Actual & Unfulfilled Demand

New page, rename to **Hospital Forecast vs Actual**. All visuals read
`v_hospital_forecast_month`.

### 6a. Forecast vs actual by hospital

1. **Clustered column chart**:
   - **X-axis:** `hospital`
   - **Values:** `Forecast Demand` and `Actual Consumed` (two columns side by side)
2. **Line chart** — trend over time:
   - **X-axis:** `month_label`
   - **Values:** `Forecast Demand`, `Actual Consumed`

### 6b. Accuracy & unfulfilled demand

3. **Table / Matrix**:
   - **Rows:** `hospital`, `hospital_type`, `state`
   - **Values:** `Forecast Demand`, `Actual Consumed`, `Actual vs Forecast %`, `Unfulfilled Demand`
   - Add conditional formatting on `Unfulfilled Demand` (Format → Cell elements →
     Background color) so shortfalls stand out.
4. **Clustered bar chart** — unfulfilled demand by hospital:
   - **Y-axis:** `hospital`
   - **X-axis:** `Unfulfilled Demand`

### 6c. Slicers on Page 2

- **Month slicer:** `month_label`
- **State slicer:** `state`

---

## 7. Page 3 — Fast vs Slow Movers

New page, rename to **Fast vs Slow Movers**. All visuals read `v_medicine_movement`.

### 7a. Fast movers (top 10)

1. **Clustered bar chart**:
   - **Y-axis:** `medicine`
   - **X-axis:** `Units Sold`
   - **Visual-level filter** (Filters pane → drag `fast_mover_rank`): filter type
     **Top N**, **Top 10** by `Units Sold` — *or* set `fast_mover_rank` **is less than
     or equal to 10**.
   - Sort the bar descending by `Units Sold`.

### 7b. Slow movers (bottom 10)

2. **Clustered bar chart**:
   - **Y-axis:** `medicine`
   - **X-axis:** `Units Sold`
   - **Visual-level filter:** `slow_mover_rank` **is less than or equal to 10**.
   - Sort ascending by `Units Sold`.

> Ranks are computed **per state per month**, so pick a single month and state in the
> slicers to read a clean top/bottom 10. With "All" selected the chart shows combined
> volumes, which is still useful but no longer a strict rank.

### 7c. Movement detail

3. **Matrix**:
   - **Rows:** `therapeutic_class`, `medicine`
   - **Values:** `Units Sold`
   - **Columns (optional):** `month_label`

### 7d. Slicers on Page 3

- **Month slicer:** `month_label`
- **State slicer:** `state`
- **Therapeutic class slicer:** `therapeutic_class`

---

## 8. Save and refresh

1. **File → Save As** → `sdi_business.pbix`.
2. After the pipeline runs again, open the file and click **Home → Refresh**. The
   views are recreated by the pipeline on every publish, so new months appear and the
   **Data as of** card updates — confirming the refresh landed.

---

## 9. Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Unable to connect" / timeout | WSL IP changed — re-run `hostname -I`, then **Transform data → Data source settings → Change Source** and update the server. |
| SSL / encryption error | You left **Encrypt connections** on — edit the source credentials and turn it **off**. |
| "password authentication failed" | Use `bi_reader` / `bi_pass` on the **Database** credential tab, not Windows auth. |
| Months out of order | Do step **2a** (Sort `month_label` by `month_key`) on each view. |
| A card is blank | `v_refresh_status` / `v_kpi_latest_month` need at least one published month — run `serving/publish_mart.py`. |
| Permission denied on a view | Re-run `sql/postgres/07_bi_views.sql` as `ida_user` (it re-grants to `bi_reader`); the pipeline also does this on every publish. |
