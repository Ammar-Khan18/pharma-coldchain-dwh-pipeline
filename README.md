# Pharma Cold-Chain Data Warehouse Pipeline

**Course project : Intelligent Data Architecture, IBA University.**

## Summary

An end-to-end data pipeline for the pharmaceutical **cold chain** — the
temperature-controlled supply chain that keeps vaccines, biologics and other
sensitive drugs within safe limits from manufacturer to patient. A bootstrap
**generator** simulates new business months; a **file-watcher** picks the CSVs up
and an Airflow **ingest** DAG loads them into a PostgreSQL **ODS** (raw, all
text); a **transform** DAG validates the data against a documented rulebook and
builds a **DuckDB star schema** (the SDI mart — two fact tables, conformed and
SCD Type 2 dimensions, junk and degenerate dimensions); the mart is **published
back to PostgreSQL** for Power BI, while **query** and **storage-metrics** DAGs
benchmark the queries and record pipeline health, all surfaced in **Grafana**.
Phase 1 (Sales & Demand Intelligence) is implemented and tested end-to-end;
Inventory (Phase 2) and cold-chain / IoT streaming (Phase 3) follow.

## Group members

| Name | Student ID | 
| --- | --- | 
| Zainab Irfan Ansari | 29091 | 
| Sumaiya Batool| 29295 | 
| Ammar Khan | 29296 | 

---

## Architecture

```
 generator/generate.py          (WBS 2.1 — simulate a new business month)
        |  writes new CSVs
        v
   landing/  ----->  ingestion/file_watcher.py  ----->  [ DAG: sdi_ingest ]
 (drop zone)          (watchdog, polling)                 COPY CSV -> ODS
                                                               |
                                                               v
                                              PostgreSQL  ods.*   (raw, every column TEXT)
                                                               |  Airflow Asset: "ODS loaded"
                                                               v
                                                     [ DAG: sdi_transform ]
                                            validate -> dims -> facts -> tests
                                            (reads ODS via DuckDB postgres ATTACH)
                                                               |
                                                               v
                                                 DuckDB  sdi.*   (star schema, OLAP engine)
                                                               |  serving/publish_mart.py
                                                               v
                                              PostgreSQL  mart.*  ---------------->  Power BI
                                                               |  Asset: "mart published"
                               +-------------------------------+-------------------------------+
                               v                                                               v
                     [ DAG: sdi_query ]                                        [ DAG: sdi_storage_metrics ]
              aggregates + raw/opt benchmark                                      per-table storage census
                               |                                                               |
                               +-------------------------------+-------------------------------+
                                                               v
                                              PostgreSQL  meta.*  (pipeline logs)  ----------->  Grafana
                                     batch_log / dq_log / query_log / storage_snapshot / pipeline_run / generation_log
```

**Flow in words:** generator → file-watcher / ingest → PostgreSQL ODS → DuckDB
SDI mart (star schema) → query layer → publish to PostgreSQL `mart` → Grafana /
Power BI. Each stage hands off to the next through **Airflow Assets**, so one
trigger of `sdi_ingest` (or a generator refresh) cascades through the whole chain
with no manual steps. DuckDB is the OLAP engine; PostgreSQL holds the raw ODS, the
served `mart` (so Windows/Power BI and Linux both read it), and the `meta` logs.

---

## Repository structure

| Folder | Purpose |
| --- | --- |
| `data/` | The 7 original source CSVs (01 master, 05 sales, 06 demand, …). *gitignored* |
| `oversampled_data/` | **Generator output** CSVs for the refresh demo + `data_dictionary.md` |
| `generator/` | `generate.py` — bootstrap data generator (simulate a new month) |
| `ingestion/` | Batch ingestion (`ingest_api.py`), file-watcher, seeder, profiling, storage metrics |
| `transform/` | `transform_lib.py` — DuckDB + Postgres ATTACH helpers for the transform |
| `query/` | `query_runner.py` — runs & times the widget queries, logs `meta.query_log` |
| `serving/` | `publish_mart.py` — copy the DuckDB `sdi` mart to Postgres `mart` |
| `sql/postgres/` | ODS tables, `meta` tables, BI access, indexes, migrations (00–06) |
| `sql/mart/` | DuckDB star schema + transform SQL (`sdi_01`…`sdi_50`) |
| `sql/queries/` | Dashboard widget queries (raw + `_opt` variants) |
| `dags/` | Airflow DAGs: `sdi_ingest`, `sdi_transform`, `sdi_query`, `sdi_storage_metrics`, `sdi_generate` |
| `bi/grafana/` | Grafana dashboards (`dashboards/*.json`), provisioning, import/export scripts |
| `bi/powerbi/` | Power BI report (reads Postgres `mart`) |
| `docs/` | Design docs, profiling report, Excel design, generator report, demo script |
| `marts/` | `sdi_mart.duckdb` (the DuckDB file). *gitignored* |
| `landing/`, `archive/` | Ingestion drop zone and processed-file archive. *gitignored* |
| `Milestone.1.SDI.DWH/` | Milestone 1 submission bundle (final Report, Excel, Video) |

---

## How to run

Everything runs in **WSL (Ubuntu)**. The repo lives at `~/pipeline`. See the
one-time setup block at the end of this section for first-time installation.

### Start routine (each session)

```bash
sudo service postgresql start                 # Postgres
sudo systemctl start grafana-server           # Grafana (http://localhost:3000)
source ~/ida-project/.venv/bin/activate       # venv
# start Airflow (scheduler + api-server + dag-processor), e.g. in three terminals:
airflow scheduler &   airflow api-server &   airflow dag-processor &
# optional: the automated file-watcher (drop a CSV in landing/ -> auto-ingest)
python ~/pipeline/ingestion/file_watcher.py &
```

### Initial load and DAG order

```bash
python ~/pipeline/ingestion/seed_landing.py   # copies 01/05/06 into landing/
airflow dags trigger sdi_ingest               # scans landing -> COPY into ODS
```

`sdi_ingest` then cascades automatically through the chain via Airflow Assets:

```
sdi_ingest  ->  sdi_transform  ->  { sdi_query , sdi_storage_metrics }
```

**Run a single DAG by hand** (same order if running manually):

```bash
airflow dags trigger sdi_ingest             # 1. CSV -> Postgres ODS (dedup by file hash)
airflow dags trigger sdi_transform          # 2. ODS -> DuckDB star -> publish to Postgres mart
airflow dags trigger sdi_query              # 3. build aggregates, benchmark raw vs optimized
airflow dags trigger sdi_storage_metrics    # 3. storage census into meta.storage_snapshot
```

**Run a refresh (simulate a new month)** — generates data, drops it in landing,
and triggers the whole chain:

```bash
airflow dags trigger sdi_generate \
  --conf '{"period": "2026-01", "price_change": 3, "bad_rows": 5}'
# period      = month to simulate (YYYY-MM)   — refresh 1 = 2026-01, refresh 2 = 2026-02
# price_change= change N medicines' price -> new dim_medicine SCD2 versions
# bad_rows    = add N invalid rows -> proves validation rejects them
```

Method and rationale: [docs/generator_method.md](docs/generator_method.md) /
[docs/generator_report.pdf](docs/generator_report.pdf). Full demo walk-through:
[docs/milestone1_demo_script.md](docs/milestone1_demo_script.md).

<details>
<summary><strong>One-time setup (first install)</strong></summary>

1. **Python venv** (Airflow 3.3.2, Python 3.14):
   ```bash
   python -m venv ~/ida-project/.venv
   source ~/ida-project/.venv/bin/activate
   pip install -r ~/pipeline/requirements.txt      # airflow, duckdb, psycopg2, watchdog, openpyxl, fpdf2, …
   ```
2. **PostgreSQL** — database `ida_staging`, owner `ida_user` / `ida_pass`, read-only `bi_reader` / `bi_pass`:
   ```bash
   sudo -u postgres psql -d ida_staging < ~/pipeline/sql/postgres/00_bi_access.sql   # roles + schemas + grants
   # then, as ida_user, create the meta / ODS tables and indexes:
   for f in 01_meta_tables 02_ods_tables 03_rejected_rows 04_query_storage_meta 05_generation_log 06_ods_indexes; do
     PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -f ~/pipeline/sql/postgres/$f.sql
   done
   ```
3. **Airflow** — connection + variables the DAGs use:
   ```bash
   airflow connections add ida_postgres \
     --conn-uri 'postgres://ida_user:ida_pass@localhost:5432/ida_staging'
   airflow variables set SOURCE_DIR  /home/<you>/pipeline/data
   airflow variables set LANDING_DIR /home/<you>/pipeline/landing
   airflow variables set ARCHIVE_DIR /home/<you>/pipeline/archive
   airflow variables set DUCKDB_DIR  /home/<you>/pipeline/marts
   ```
   The DAGs are discovered from `~/pipeline/dags` (the effective `dags_folder`).
4. **Grafana** (v13 at `http://localhost:3000`) — the `ida_postgres` data source is
   provisioned from `bi/grafana/provisioning/datasources/`. Import the dashboards:
   ```bash
   export GRAFANA_USER=admin GRAFANA_PASSWORD='<admin-pw>'
   bash ~/pipeline/bi/grafana/import_dashboards.sh      # repo JSON -> Grafana
   # inverse (Grafana -> repo JSON, after editing in the UI):
   bash ~/pipeline/bi/grafana/export_dashboards.sh
   ```
</details>

