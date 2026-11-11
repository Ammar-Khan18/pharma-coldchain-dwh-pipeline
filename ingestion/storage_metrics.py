"""
storage_metrics.py  —  Phase 1 storage metrics (WBS 2.4.3).

Writes one meta.storage_snapshot row per table, so the "storage" dashboard can
show how big each layer is and how storage is shared across the source domains
(01 master / 05 sales / 06 hospital demand) over time.

What it records:
  * Postgres schemas ods, meta, mart — row count and size in MB
    (pg_total_relation_size) per table.
  * DuckDB schema sdi — row count per table, plus the DuckDB file size.
  * Date coverage (min date, max date, distinct year-months) for the fact tables
    and the ODS sales/demand tables.
  * A source_domain tag on every row (master / sales / hospital_demand /
    conformed / observability) for the storage-share-by-source view.

Standalone (Ubuntu/WSL, venv active):
    python ~/pipeline/ingestion/storage_metrics.py
"""
import os
import sys
from pathlib import Path

import duckdb
import psycopg2

PG_DSN = os.environ.get(
    "IDA_PG_DSN",
    "host=localhost port=5432 dbname=ida_staging user=ida_user password=ida_pass",
)


def duckdb_path() -> Path:
    duck_dir = os.environ.get("DUCKDB_DIR", str(Path.home() / "pipeline" / "marts"))
    return Path(duck_dir) / "sdi_mart.duckdb"


def _domain_for(table: str) -> str:
    """Tag a table with the source domain it belongs to."""
    t = table.lower()
    if "master" in t or t == "dim_medicine":
        return "master"
    if "hospital_demand" in t or "demand" in t or t == "dim_hospital":
        return "hospital_demand"
    if "sales" in t or t in ("dim_pharmacy", "dim_channel", "dim_sales_profile"):
        return "sales"
    if t == "dim_date":
        return "conformed"
    if t == "rejected_rows" or t.endswith("_log") or t in ("pipeline_run", "storage_snapshot"):
        return "observability"
    return "other"


# Date-coverage queries keyed by (layer, table). Each returns (min_date, max_date, distinct_months).
def _coverage_pg(cur, schema: str, table: str):
    if (schema, table) == ("ods", "pharmacy_sales"):
        cur.execute('SELECT min("SalesDate"::date), max("SalesDate"::date), '
                    'count(DISTINCT substr("SalesDate",1,7)) FROM ods.pharmacy_sales')
    elif (schema, table) == ("ods", "hospital_demand"):
        cur.execute('SELECT min("DemandMonth"::date), max("DemandMonth"::date), '
                    'count(DISTINCT substr("DemandMonth",1,7)) FROM ods.hospital_demand')
    elif (schema, table) == ("mart", "fact_sales"):
        cur.execute("SELECT min(d.full_date), max(d.full_date), count(DISTINCT d.year_month) "
                    "FROM mart.fact_sales f JOIN mart.dim_date d ON d.date_key=f.sale_date_key "
                    "WHERE f.sale_date_key <> -1")
    elif (schema, table) == ("mart", "fact_hospital_demand"):
        cur.execute("SELECT min(d.full_date), max(d.full_date), count(DISTINCT d.year_month) "
                    "FROM mart.fact_hospital_demand f JOIN mart.dim_date d ON d.date_key=f.month_date_key "
                    "WHERE f.month_date_key <> -1")
    else:
        return (None, None, None)
    return cur.fetchone()


def _coverage_duck(con, table: str):
    if table == "fact_sales":
        return con.execute(
            "SELECT min(d.full_date), max(d.full_date), count(DISTINCT d.year_month) "
            "FROM sdi.fact_sales f JOIN sdi.dim_date d ON d.date_key=f.sale_date_key "
            "WHERE f.sale_date_key <> -1").fetchone()
    if table == "fact_hospital_demand":
        return con.execute(
            "SELECT min(d.full_date), max(d.full_date), count(DISTINCT d.year_month) "
            "FROM sdi.fact_hospital_demand f JOIN sdi.dim_date d ON d.date_key=f.month_date_key "
            "WHERE f.month_date_key <> -1").fetchone()
    return (None, None, None)


def snapshot(dsn: str = PG_DSN, duck_path: Path | None = None, batch_id: str | None = None) -> int:
    """Collect storage metrics and append them to meta.storage_snapshot. Returns rows written."""
    duck_path = duck_path or duckdb_path()
    rows = []   # (layer, source_domain, table_name, row_count, size_mb, min_date, max_date, distinct_months)

    # ---- Postgres schemas ods, meta, mart --------------------------------
    with psycopg2.connect(dsn) as conn, conn.cursor() as cur:
        for schema in ("ods", "meta", "mart"):
            cur.execute(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema=%s AND table_type='BASE TABLE' ORDER BY table_name", (schema,))
            for (tbl,) in cur.fetchall():
                cur.execute(f'SELECT count(*) FROM {schema}."{tbl}"')
                n = cur.fetchone()[0]
                cur.execute("SELECT pg_total_relation_size(%s)", (f'{schema}."{tbl}"',))
                size_mb = round(cur.fetchone()[0] / 1_048_576, 2)
                mn, mx, dm = _coverage_pg(cur, schema, tbl)
                rows.append((schema, _domain_for(tbl), f"{schema}.{tbl}", n, size_mb, mn, mx, dm))

    # ---- DuckDB schema sdi ----------------------------------------------
    con = duckdb.connect(str(duck_path), read_only=True)
    try:
        sdi_tabs = [r[0] for r in con.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema='sdi' ORDER BY table_name").fetchall()]
        for tbl in sdi_tabs:
            n = con.execute(f'SELECT count(*) FROM sdi."{tbl}"').fetchone()[0]
            mn, mx, dm = _coverage_duck(con, tbl)
            rows.append(("duckdb", _domain_for(tbl), f"sdi.{tbl}", n, None, mn, mx, dm))
    finally:
        con.close()
    # the DuckDB file size, as one summary row
    file_mb = round(os.path.getsize(duck_path) / 1_048_576, 2)
    rows.append(("duckdb", "duckdb_file", Path(duck_path).name, None, file_mb, None, None, None))

    # ---- write ----------------------------------------------------------
    with psycopg2.connect(dsn) as conn, conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO meta.storage_snapshot "
            "(etl_batch_id, layer, source_domain, table_name, row_count, size_mb, "
            " min_date, max_date, distinct_year_months) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
            [(batch_id, *r) for r in rows],
        )
    print(f"storage_metrics: wrote {len(rows)} rows to meta.storage_snapshot")
    return len(rows)


if __name__ == "__main__":
    snapshot(batch_id="manual_" + __import__("time").strftime("%Y%m%dT%H%M%S"))
