# Milestone 1 — 7-minute live demo script

A step-by-step script for the live demo: **what to open, what to click, what to
say**. The highlight is a live generator refresh (Refresh 2 = **2026-02**) that
makes the warehouse and dashboards visibly move. Keep Refresh 2 for the demo —
do not run it beforehand.

---

## Pre-flight (do this ~5 minutes before the audience arrives)

```bash
sudo service postgresql start
sudo systemctl start grafana-server
source ~/ida-project/.venv/bin/activate
airflow scheduler & airflow api-server & airflow dag-processor &
```

- [ ] `airflow dags list-import-errors` → **"No data found"** (all DAGs parse).
- [ ] All five `sdi_*` DAGs **unpaused** (`airflow dags list`).
- [ ] `landing/` is empty and the chain is idle.
- [ ] **Refresh 2 (2026-02) has NOT been run yet** (`meta.generation_log` has only `2026-01`).
- [ ] Browser tabs open: the 4 Grafana dashboards (`http://localhost:3000`), the
      Airflow UI, and (optional) the Power BI report.
- [ ] One terminal ready with the **counts** command below.

**Counts command** (copy-paste; shows the numbers that will change):
```bash
psql "postgresql://ida_user:ida_pass@localhost/ida_staging" -c "SELECT
  (SELECT count(*) FROM mart.fact_sales)            AS fact_sales,
  (SELECT count(*) FROM mart.fact_hospital_demand)  AS fact_demand,
  (SELECT count(*) FROM mart.dim_medicine)          AS dim_medicine_versions,
  (SELECT count(*) FROM ods.rejected_rows)          AS rejected_rows;"
```
Expected **before** Refresh 2: `fact_sales ~513,889 · fact_demand 27,972 · dim_medicine_versions 67 · rejected_rows 5`.

---

## Timeline (7:00)

### 0:00–1:00 — Problem & architecture
- Open the README architecture diagram. One line: *"A pharma cold-chain data
  warehouse; this is Phase 1 — Sales & Demand Intelligence."*
- Trace the diagram: **generator → landing → file-watcher → sdi_ingest → Postgres
  ODS → sdi_transform → DuckDB star → publish → Postgres mart → Power BI**, and
  **meta logs → Grafana**.
- Say: *"Every stage hands off to the next through Airflow Assets, so one trigger
  runs the whole chain automatically."*

### 1:00–2:30 — The warehouse & dashboards as they stand
Walk the four Grafana dashboards (10s auto-refresh):
- **Storage** — donut of storage by source domain; date coverage **2023-01 → 2026-01
  (37 months)**; total rows; DuckDB file size. *"ODS raw text is heaviest; the
  served mart is lean."*
- **Query Performance** — the raw-vs-optimized bar chart. *"Reading pre-aggregates
  instead of scanning 500k+ rows is ~2–4× faster."*
- **Data Quality** — rules evaluated = 31; **rows rejected = 5** (the injected bad
  rows); rows warned = 0. *"Validation ran on every row; the data is clean."*
- **Batch Ingestion** — success rate 100%; load duration per file; last loads.

### 2:30–3:00 — Capture the "before" numbers
- Run the **counts command**. Read them out: *"513,889 sales facts, 67 medicine
  versions, 5 rejected rows. Watch these move."*

### 3:00–5:00 — Run a live refresh (the star of the show)
```bash
airflow dags trigger sdi_generate \
  --conf '{"period": "2026-02", "price_change": 2, "bad_rows": 4}'
```
While it runs, explain: *"This generates one realistic new month — about 13,900
sales and 756 hospital-demand rows, resampled from real history — changes the
price of 2 medicines, and slips in 4 deliberately bad rows."*
- In the **Airflow UI**, watch the cascade light up green:
  `sdi_generate → sdi_ingest → sdi_transform → { sdi_query, sdi_storage_metrics }`.

### 5:00–6:30 — Show the change
- Re-run the **counts command**:
  - `fact_sales` **+~13,900** (now ~527,800), `fact_demand` **+756** (28,728),
    `dim_medicine_versions` **+2** (69 — two new SCD2 versions), `rejected_rows`
    **+4** (9 — the new bad rows, each counted once).
- Refresh the Grafana tabs (auto-refreshes within 10s):
  - **Storage** — date coverage now **…→ 2026-02 (38 months)**; totals up.
  - **Data Quality** — the **4 new rejections** appear in the per-run summary.
  - **Batch Ingestion** — the new generated files show as fresh loads.
- (Optional) **Power BI** — refresh; the new month appears in the channel-revenue
  chart and the KPI cards.

### 6:30–7:00 — Wrap
- *"Every number reconciled: ODS rows = fact rows loaded + rejected rows, and the
  DuckDB `sdi` star matches the Postgres `mart` exactly."*
- Point to the artifacts: the **Excel design file** (`docs/phase1_sdi_design.xlsx`),
  the **generator report** (`docs/generator_report.pdf`), and the **validation
  rulebook** (31 rules). *"Phase 2 (inventory) and Phase 3 (cold-chain IoT
  streaming) build on the same conformed dimensions."*

---

## If something goes wrong
- **A DAG goes red** → open `meta.pipeline_run` (a `FAILED` row with the reason is
  written automatically) and the Airflow task log.
- **The chain didn't cascade** → trigger the next stage by hand:
  `airflow dags trigger sdi_transform`.
- **No new data appeared** → confirm the generated files landed
  (`ls ~/pipeline/landing`); re-run `sdi_generate`.
- **Dashboard looks empty** → it's the 7-day window; the refresh you just ran is
  inside it, so give it the 10s auto-refresh.
