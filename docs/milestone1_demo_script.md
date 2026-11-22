# Milestone 1 — 7-minute live demo script

A step-by-step script for the live demo: **what to open, what to click, what to
say**. The highlight is a live generator refresh (**2026-03**) that makes the
warehouse and dashboards visibly move. Refreshes **2026-01 and 2026-02 are already
loaded**, so the live one is **2026-03** — do not run it beforehand.

All tables and columns are PascalCase (`FactPharmacySales`, `DimMedicine`, …) and
quoted in SQL.

---

## Pre-flight (do this ~5 minutes before the audience arrives)

```bash
sudo service postgresql start
sudo systemctl start grafana-server
source ~/ida-project/.venv/bin/activate
export PYTHONDONTWRITEBYTECODE=1                 # avoid stale .pyc on WSL/DrvFS
# clear any stale compiled DAG/module copies and re-serialize from current source:
find ~/pipeline -name __pycache__ -type d -prune -exec rm -rf {} +
airflow dags reserialize
airflow scheduler & airflow api-server & airflow dag-processor &
```

- [ ] `airflow dags list-import-errors` → **"No data found"** (all DAGs parse).
- [ ] All five `sdi_*` DAGs **unpaused** (`airflow dags list`).
- [ ] `landing/` is empty and the chain is idle.
- [ ] **2026-03 has NOT been run yet** (`meta.generation_log` shows only `2026-01` and `2026-02`).
- [ ] **Power BI data source** points at the right host: the report's Postgres source must use
      this machine's current IP (check `hostname -I`); Power BI runs on Windows and cannot reach
      `localhost` inside WSL. Re-point it if the IP changed, then test the connection.
- [ ] Browser tabs open: the 4 Grafana dashboards (`http://localhost:3000`), the Airflow UI,
      and (optional) the Power BI report.
- [ ] One terminal ready with the **counts** command below.

**Counts command** (copy-paste; shows the numbers that will change):
```bash
psql "postgresql://ida_user:ida_pass@localhost/ida_staging" -c "SELECT
  (SELECT count(*) FROM mart.\"FactPharmacySales\")  AS fact_pharmacy_sales,
  (SELECT count(*) FROM mart.\"FactHospitalDemand\") AS fact_hospital_demand,
  (SELECT count(*) FROM mart.\"DimMedicine\")        AS dim_medicine_rows,
  (SELECT count(*) FROM mart.\"DimMedicine\" WHERE \"IsCurrent\"='Y') AS current_versions,
  (SELECT max(\"FullDate\") FROM mart.\"DimDate\" WHERE \"DateKey\"<>-1) AS dimdate_max,
  (SELECT count(*) FROM ods.rejected_rows) AS rejected_rows;"
```
Expected **before** the live 2026-03 refresh (2026-01 + 2026-02 already loaded):
`fact_pharmacy_sales 527,413 · fact_hospital_demand 28,728 · dim_medicine_rows 66 · current_versions 64 · dimdate_max 2026-12-31`.

> **Verified in testing (the 2026-02 refresh), the concrete magnitude of one refresh:**
> `FactPharmacySales 513,889 → 527,413 (+13,524)`, `FactHospitalDemand 27,972 → 28,728 (+756)`,
> `DimMedicine 64 → 66` (two new SCD2 versions, MED022 + MED001 flipped Rx→OTC), **5 bad rows rejected**.

> **Note — a bare `sdi_ingest` with an empty `landing/` does nothing.** With no files, the
> mapped ingest task has zero expansions, the ODS Asset is not produced, and the chain does
> **not** cascade. That is why the demo starts with the **generator**, which writes the files
> into `landing/` and then triggers `sdi_ingest` itself.

---

## Timeline (7:00)

### 0:00–1:00 — Problem & architecture
- Open the README architecture diagram. One line: *"A pharma cold-chain data warehouse;
  this is Phase 1 — Sales & Demand Intelligence."*
- Trace the diagram: **generator → landing → file-watcher → sdi_ingest → Postgres ODS →
  sdi_transform → DuckDB PascalCase star → publish → Postgres mart → Power BI**, and
  **meta logs → Grafana**.
- Say: *"Every stage hands off to the next through Airflow Assets, so one trigger runs the
  whole chain automatically."*

### 1:00–2:30 — The warehouse & dashboards as they stand
Walk the four Grafana dashboards (10s auto-refresh):
- **Storage** — storage by source domain; date coverage **2023-01 → 2026-02**; total rows;
  **DuckDB file ≈ 61 MB**, monthly **Parquet partitions ≈ 10 MB**. *"ODS raw text is
  heaviest; the served mart is lean."*
- **Query Performance** — the **base vs aggregate** bar chart: *"Reading the pre-aggregate
  tables instead of scanning 500k+ fact rows is ~3–8× faster."* Point at the lower
  **"table vs Parquet partition"** panel and say plainly: *"Partitioning here is a
  **storage/access** choice, not a speed-up — one month of Parquet is ~10 MB and readable
  without opening the database; on this WSL disk the partition read (44 ms) is actually
  slower than the indexed table (13 ms), and we label it so it isn't mistaken for a
  regression."*
- **Data Quality** — rules evaluated; **rows rejected** (the injected bad rows); rows warned.
  *"Validation ran on every row; the data is clean."*
- **Batch Ingestion** — success rate 100%; load duration per file; last loads.

### 2:30–3:00 — Capture the "before" numbers
- Run the **counts command**. Read them out: *"527,413 sales facts, 66 medicine rows
  (64 current versions). Watch these move."*

### 3:00–5:00 — Run a live refresh (the star of the show)
```bash
airflow dags trigger sdi_generate \
  --conf '{"period": "2026-03", "price_change": 0, "bad_rows": 5}'
```
While it runs, explain: *"This generates one realistic new month — about 13,500 sales and
756 hospital-demand rows, resampled from real history — and slips in 5 deliberately bad rows.
Each refresh also deterministically flips the prescription class of one or two medicines, so
a new SCD2 version appears."*
- In the **Airflow UI**, watch the cascade light up green:
  `sdi_generate → sdi_ingest → sdi_transform → { sdi_query, sdi_storage_metrics }`.
- **The SCD2 moment — `MED037`.** For 2026-03 the generator flips **MED037** from
  `Prescription` to `OTC` (deterministic). Show both versions:
  ```bash
  psql "postgresql://ida_user:ida_pass@localhost/ida_staging" -c "SELECT
    \"MedicineID\", \"PresClass\", \"EffectiveFrom\", \"EffectiveTo\", \"IsCurrent\"
  FROM mart.\"DimMedicine\" WHERE \"MedicineID\"='MED037' ORDER BY \"EffectiveFrom\";"
  ```
  *"The old `Prescription` version closes at 2026-02-28 and a new `OTC` version opens at
  2026-03-01 — and March sales of MED037 point to the new version, February sales keep the old one."*

### 5:00–6:30 — Show the change
- Re-run the **counts command**:
  - `fact_pharmacy_sales` **+~13,500** (~541,000), `fact_hospital_demand` **+756** (29,484),
    `dim_medicine_rows` **+1** (67 — one new SCD2 version), `rejected_rows` **+5**.
- Show **q1 (channel margin) for the brand-new month**:
  ```bash
  psql "postgresql://ida_user:ida_pass@localhost/ida_staging" -c "SELECT
    \"Year\",\"Month\",\"SalesChannel\",\"NetSales\",\"GrossMargin\",round(\"GrossMarginPct\"::numeric,4) AS margin_pct
  FROM mart.agg_channel_month WHERE \"Year\"=2026 AND \"Month\"=3 ORDER BY \"SalesChannel\";"
  ```
  *"2026-03 did not exist a minute ago; now both channels are there with their margins."*
- Refresh the Grafana tabs (auto-refreshes within 10s):
  - **Storage** — date coverage now **…→ 2026-03**; totals up.
  - **Data Quality** — the **5 new rejections** appear in the per-run summary.
  - **Batch Ingestion** — the new generated files show as fresh loads.
- (Optional) **Power BI** — refresh; the new month appears in the channel-margin chart and KPIs.

### 6:30–7:00 — Wrap
- *"Every number reconciled: ODS rows = fact rows loaded + rejected rows, and the DuckDB
  `sdi` star matches the Postgres `mart` exactly (10 tables, equal counts)."*
- Point to the artifacts: the **Excel design file** (`docs/phase1_sdi_design.xlsx`), the
  **text design** (`docs/phase1_sdi_design.md`), and the **generator report**
  (`docs/generator_report.pdf`). *"Phase 2 (inventory) and Phase 3 (cold-chain IoT streaming)
  build on the same conformed dimensions `DimDate` / `DimMedicine` / `DimLocation`."*

---

## If something goes wrong
- **A DAG goes red** → open `meta.pipeline_run` (a `FAILED` row with the reason is written
  automatically) and the Airflow task log.
- **Airflow ran old code** (e.g. a dropped table error, or `mart.fact_sales` in a message) →
  you edited code without clearing caches: `find ~/pipeline -name __pycache__ -type d -prune
  -exec rm -rf {} +` then `airflow dags reserialize`, and re-trigger.
- **The chain didn't cascade** → confirm the generated files landed (`ls ~/pipeline/landing`);
  a bare `sdi_ingest` on an empty `landing/` will not cascade. Re-run `sdi_generate`, or trigger
  the next stage by hand: `airflow dags trigger sdi_transform`.
- **Power BI shows nothing / can't connect** → the data source IP is stale; re-point it to
  `hostname -I` and test.
- **Dashboard looks empty** → it's the time window; the refresh you just ran is inside it, so
  give it the 10s auto-refresh.
