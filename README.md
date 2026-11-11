# Pharma Cold-Chain Data Warehouse Pipeline

An end-to-end data pipeline for monitoring the pharmaceutical **cold chain** — the
temperature-controlled supply chain that keeps vaccines, biologics, and other
sensitive drugs within safe limits from manufacturer to patient.

The project ingests sensor and shipment data, loads it into a data warehouse,
transforms it into analytics-ready models, and surfaces cold-chain excursions and
KPIs through dashboards.

## Repository structure

| Folder         | Purpose                                                             |
| -------------- | ------------------------------------------------------------------- |
| `generator/`   | Synthetic data generators (shipments, IoT temperature readings)     |
| `data/`        | Raw / sample data files                                             |
| `ingestion/`   | Batch ingestion (CSV → Postgres ODS) and the file-watcher           |
| `transform/`   | SDI transform helpers (ODS → DuckDB star)                           |
| `serving/`     | Publish the DuckDB mart to Postgres `mart` for Power BI             |
| `sql/`         | Raw SQL — `postgres/` (ODS, meta), `mart/` (DuckDB star + tests)    |
| `dags/`        | Airflow DAGs orchestrating the pipeline                             |
| `bi/`          | BI assets (`grafana/`, `powerbi/`)                                  |
| `docs/`        | Project documentation                                               |

## Phase 1 — SDI transform layer (ODS → star → mart)

The **Sales & Demand Intelligence (SDI)** transform turns the raw ODS tables into
a dimensional star schema and serves it to Power BI:

```
Postgres ods.*  ──►  DuckDB sdi.* (star schema)  ──►  Postgres mart.*
(raw, all TEXT)      validate → dims → facts → tests     (served to Power BI)
```

DuckDB is the OLAP engine (schema `sdi` in `marts/sdi_mart.duckdb`); it reads the
ODS straight from Postgres with the DuckDB **postgres extension** (`ATTACH`, no
copy). The finished mart is published to Postgres schema `mart` so Windows (Power
BI) and Linux tools can both read it. Design: [docs/phase1_sdi_design.md](docs/phase1_sdi_design.md).

### Files

| File | Purpose |
| --- | --- |
| `dags/sdi_transform.py` | Airflow DAG, one task per step, `retries=2` |
| `transform/transform_lib.py` | Opens DuckDB + attaches Postgres; ships rejected rows / DQ counts to Postgres (psycopg2) |
| `sql/mart/sdi_10_validate.sql` | Apply REJECT/WARN rules (M1–M6, S1–S16, H1–H9); cast & clean (zero-pad GTIN14/GLN/SSCC18) |
| `sql/mart/sdi_20_dims.sql` | `dim_medicine` (SCD2), `dim_pharmacy`/`dim_hospital` (SCD1), junk dims; `dim_date`/`dim_channel` reused |
| `sql/mart/sdi_30_facts.sql` | Append `fact_sales` + `fact_hospital_demand` (skip keys already loaded) |
| `sql/mart/sdi_40_tests.sql` | Data tests: unique keys, no NULL FKs, FK-in-dim, row-count reconciliation |
| `sql/postgres/03_rejected_rows.sql` | `ods.rejected_rows` — quarantine for rows that fail a REJECT rule |

> Staging tables live in a separate DuckDB schema **`stg`** (not `sdi`) so
> `serving/publish_mart.py`, which copies every table in `sdi`, never publishes them.

### Pipeline steps

`start_run → validate → build_dims → build_facts → data_tests → publish_mart → finish`

1. **start_run** — open a `meta.pipeline_run` row; mint the transform `etl_batch_id`.
2. **validate** — apply the rulebook. **REJECT** rows are quarantined in
   `ods.rejected_rows` (with the rule, a reason, and the raw row as JSON);
   **WARN** rows still load but raise `dq_warning_count`. Per-rule pass/fail
   tallies go to `meta.dq_log`.
3. **build_dims** — `dim_medicine` keeps history (SCD Type 2: a new version only
   when a tracked attribute — price/cost, status, Rx class, cold chain, storage
   limits — changes); pharmacies/hospitals overwrite (SCD Type 1); junk dims add
   only new flag combinations. The `-1` "Unknown / N/A" member backs every dim.
4. **build_facts** — append both facts, resolving all surrogate keys (unmatched →
   `-1`), skipping natural keys already loaded (append-only, no double counting).
5. **data_tests** — fail the run if any test fails (nothing broken reaches Power BI).
6. **publish_mart** — `serving/publish_mart.py` copies `sdi` → Postgres `mart`.
7. **finish** — close the `pipeline_run` row SUCCESS / FAILED.

### Running it

```bash
# WSL, venv active. Needs the ODS loaded first (see the ingestion layer).
airflow dags trigger sdi_transform
```

**Automation:** `sdi_transform` is scheduled on the Airflow **Asset** that
`sdi_ingest` produces on success, so a successful batch ingest triggers the
transform automatically (no manual step).

## Status

Phase 1 batch ingestion and the SDI transform layer are implemented and tested
end-to-end. Streaming (IoT), inventory and cold-chain phases to follow.

## Tech stack

- **Orchestration:** Apache Airflow 3.3
- **ODS / serving store:** PostgreSQL (`ods`, `meta`, `mart` schemas)
- **OLAP / transformation:** DuckDB (star schema in SQL)
- **Dashboards:** Power BI (mart) and Grafana (pipeline observability)

---

_Course project — Intelligent Data Architecture, IBA University._
