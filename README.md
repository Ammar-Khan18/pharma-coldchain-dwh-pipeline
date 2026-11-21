# Pharma Cold-Chain Data Warehouse Pipeline

**Course project — Intelligent Data Architecture, IBA University.**
**Milestone 1 — Sales & Demand Intelligence (SDI) data warehouse.**

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
| --- | --- | --- |
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

---

## Milestone 1 deliverables

| Deliverable | Location |
| --- | --- |
| **Report** | `Milestone.1.SDI.DWH/` (final PDF) · design: [docs/phase1_sdi_design.md](docs/phase1_sdi_design.md) · generator: [docs/generator_report.pdf](docs/generator_report.pdf) |
| **Excel design file** | [docs/phase1_sdi_design.xlsx](docs/phase1_sdi_design.xlsx) — rebuild: `python docs/build_design_xlsx.py` |
| **Video** | `Milestone.1.SDI.DWH/` (demo recording) · script: [docs/milestone1_demo_script.md](docs/milestone1_demo_script.md) |
| **Oversampled data** | [oversampled_data/](oversampled_data/) — generator output CSVs + [data_dictionary.md](oversampled_data/data_dictionary.md) |

Supporting documentation:

| What | Location |
| --- | --- |
| **Design doc** (grain, dims, facts, rules, bus matrix) | [docs/phase1_sdi_design.md](docs/phase1_sdi_design.md) |
| **Profiling / assumption reports** | [docs/data_profiling_report.md](docs/data_profiling_report.md), [docs/phase1_assumption_checks.md](docs/phase1_assumption_checks.md) |
| **Grafana dashboards** | `bi/grafana/dashboards/*.json` (import/export: `bi/grafana/*_dashboards.sh`) |
| **Power BI report** | `bi/powerbi/sdi_business.pbix` (reads Postgres `mart`) |

| WBS | Deliverable | Files |
| --- | --- | --- |
| 1.3.6 | BI access + Grafana data source | `sql/postgres/00_bi_access.sql`, `bi/grafana/provisioning/datasources/` |
| 1.4 | Source profiling + assumption checks | `ingestion/profile_sources.py`, `ingestion/check_phase1_assumptions.py`, docs |
| 2.1 | Data oversampling / generator | `generator/generate.py`, `dags/sdi_generate.py`, `sql/postgres/05_generation_log.sql` |
| 2.x | Batch ingestion + file-watcher | `ingestion/ingest_api.py`, `file_watcher.py`, `seed_landing.py`, `dags/sdi_ingest.py`, `sql/postgres/02_ods_tables.sql` |
| 2.4.3 | Storage metrics | `ingestion/storage_metrics.py`, `dags/sdi_storage_metrics.py` |
| 2.6 / 3.4 | Query layer + benchmarks | `sql/queries/`, `sql/mart/sdi_50_aggregates.sql`, `query/query_runner.py`, `dags/sdi_query.py` |
| 3.1 | Dimensional model (star schema) | `sql/mart/sdi_01_create_schema.sql`, `docs/phase1_sdi_design.*` |
| 3.2.2 | Validation rules | `sql/mart/sdi_10_validate.sql`, `sql/postgres/03_rejected_rows.sql` |
| 3.3 | Serving / publish to mart | `serving/publish_mart.py`, `dags/sdi_transform.py` |
| (obs) | Pipeline logs + dashboards | `sql/postgres/01_meta_tables.sql`, `bi/grafana/dashboards/` |

---

## Reference — Phase 1 layers in detail

### SDI transform (ODS → star → mart)

```
Postgres ods.*  --->  DuckDB sdi.* (star schema)  --->  Postgres mart.*
(raw, all TEXT)       validate -> dims -> facts -> tests     (served to Power BI)
```

DuckDB reads the ODS straight from Postgres with the **postgres extension**
(`ATTACH`, no copy). Staging tables live in a separate DuckDB schema **`stg`**
(not `sdi`) so `publish_mart.py`, which copies every table in `sdi`, never
publishes them. Steps:

1. **start_run** — open a `meta.pipeline_run` row; mint the transform `etl_batch_id`.
2. **validate** — apply the rulebook (M1–M6, S1–S16, H1–H9). **REJECT** rows are
   quarantined in `ods.rejected_rows`; **WARN** rows load with `dq_warning_count`
   raised. Per-rule tallies go to `meta.dq_log`. Rejections are idempotent — a row
   already rejected is not re-validated or re-counted on later runs.
3. **build_dims** — `dim_medicine` SCD Type 2 (price/cost/status/cold-chain/storage
   changes make a new version); `dim_pharmacy`/`dim_hospital` SCD Type 1; junk dims
   add only new flag combinations; every dim has a `-1` Unknown member.
4. **build_facts** — append both facts, resolving all surrogate keys (unmatched →
   `-1`), skipping natural keys already loaded (append-only, no double counting).
5. **data_tests** — unique keys, no NULL FKs, FK-in-dim, row-count reconciliation;
   the run fails if any test fails.
6. **publish_mart** — `serving/publish_mart.py` copies `sdi` → Postgres `mart`.
7. **finish** — close the `pipeline_run` row; a failure callback records FAILED.

### Query layer (benchmarks)

Each widget has a **raw** (fact-scan) and an **optimized** (`sql/queries/*_opt.sql`,
reads the `agg_` tables) variant; `sdi_query` rebuilds the aggregates, benchmarks
both 5× each, simulates a dashboard refresh, and publishes the aggregates — logging
every run to `meta.query_log`. Optimized runs ~1.4–4.4× faster.

### Storage metrics

`ingestion/storage_metrics.py` writes `meta.storage_snapshot`: per-table row counts
and MB for `ods` / `meta` / `mart` and DuckDB `sdi` (+ the `.duckdb` file size),
plus date coverage, tagged by source domain. `sdi_storage_metrics` runs hourly and
after every transform.

---

## Tech stack

- **Orchestration:** Apache Airflow 3.3 (Asset-driven DAG chaining)
- **ODS / serving store / logs:** PostgreSQL (`ods`, `meta`, `mart` schemas)
- **OLAP / transformation:** DuckDB (star schema in SQL)
- **Dashboards:** Power BI (mart) and Grafana (pipeline observability)

---

_Course project — Intelligent Data Architecture, IBA University._
