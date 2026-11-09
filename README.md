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
| `ingestion/`   | Ingestion and loading scripts into the warehouse                    |
| `sql/`         | Raw SQL (DDL, staging, warehouse schema)                            |
| `dbt/`         | dbt project for data transformation and modeling                    |
| `dags/`        | Airflow DAGs orchestrating the pipeline                             |
| `dashboards/`  | Dashboard definitions / BI assets                                   |
| `docs/`        | Project documentation                                               |

## Status

Project scaffold. Folder structure is in place; implementation to follow.

## Tech stack (planned)

- **Orchestration:** Apache Airflow
- **Transformation:** dbt
- **Warehouse / SQL:** (TBD)
- **Dashboards:** (TBD)

---

_Course project — Intelligent Data Architecture, IBA University._
