"""
Publish the DuckDB mart to Postgres (schema `mart`) so Power BI can read it.
WBS 1.3.6 / 3.3. Later this runs as the last task of the transform DAG.

WHY
  DuckDB is a single file that only one program can write at a time, and it sits
  inside Linux. Power BI runs on Windows. So after each transform we place a copy
  of every mart table on a "serving shelf" in Postgres, which both Windows and
  Linux tools can read at the same time.
  DuckDB stays the OLAP engine: transformations and the query layer run there.

HOW
  For each table in DuckDB schema `sdi`: export it to CSV, then in ONE Postgres
  transaction, TRUNCATE the mart copy and COPY the new rows in. Power BI never sees
  a half-refreshed mart. Tables are created automatically, and recreated if their
  columns change.

WHERE TO RUN
  Ubuntu (WSL), venv active:
      python ~/pipeline/serving/publish_mart.py
  Optional env vars: SDI_DUCKDB (path to .duckdb), IDA_PG_DSN (psycopg2 DSN).
"""
import os
import sys
import tempfile
import time
from pathlib import Path

import duckdb
import psycopg2

DUCKDB_PATH = Path(os.environ.get("SDI_DUCKDB", Path.home() / "pipeline" / "marts" / "sdi_mart.duckdb"))
PG_DSN = os.environ.get("IDA_PG_DSN",
                        "host=localhost port=5432 dbname=ida_staging user=ida_user password=ida_pass")
SOURCE_SCHEMA = "sdi"
TARGET_SCHEMA = "mart"


def pg_type(duck_type: str) -> str:
    """Translate a DuckDB column type into a Postgres one."""
    t = duck_type.upper()
    if t.startswith("DECIMAL") or t.startswith("NUMERIC"):
        return t.replace("DECIMAL", "NUMERIC")
    return {
        "TINYINT": "SMALLINT", "SMALLINT": "SMALLINT", "INTEGER": "INTEGER",
        "BIGINT": "BIGINT", "HUGEINT": "NUMERIC(38,0)", "DOUBLE": "DOUBLE PRECISION",
        "FLOAT": "REAL", "VARCHAR": "TEXT", "BOOLEAN": "BOOLEAN", "DATE": "DATE",
        "TIMESTAMP": "TIMESTAMP", "TIMESTAMP WITH TIME ZONE": "TIMESTAMPTZ",
        "TIME": "TIME", "UUID": "UUID",
    }.get(t, "TEXT")


def publish(duckdb_path=DUCKDB_PATH, pg_dsn=PG_DSN, source_schema=SOURCE_SCHEMA,
            target_schema=TARGET_SCHEMA) -> list[dict]:
    """Copy every table of duckdb `source_schema` into postgres `target_schema`.
    Returns one dict per table: table, rows, seconds."""
    duck = duckdb.connect(str(duckdb_path), read_only=True)
    tables = [r[0] for r in duck.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_catalog = current_database() AND table_schema = ? "
        "AND table_type = 'BASE TABLE' ORDER BY table_name", [source_schema]).fetchall()]
    if not tables:
        sys.exit(f"No tables in DuckDB schema '{source_schema}' ({duckdb_path}). Run the schema DDL first.")

    pg = psycopg2.connect(pg_dsn)
    results = []
    try:
        with pg, pg.cursor() as cur, tempfile.TemporaryDirectory() as tmp:
            for tbl in tables:
                t0 = time.time()
                cols = duck.execute(
                    "SELECT column_name, data_type FROM information_schema.columns "
                    "WHERE table_catalog = current_database() AND table_schema = ? AND table_name = ? "
                    "ORDER BY ordinal_position", [source_schema, tbl]).fetchall()
                wanted = [(c, pg_type(t)) for c, t in cols]

                # Does the Postgres copy exist with the same columns? If not, rebuild it.
                cur.execute("SELECT column_name FROM information_schema.columns "
                            "WHERE table_schema = %s AND table_name = %s ORDER BY ordinal_position",
                            (target_schema, tbl))
                existing = [r[0] for r in cur.fetchall()]
                if existing != [c for c, _ in wanted]:
                    cur.execute(f'DROP TABLE IF EXISTS {target_schema}."{tbl}"')
                    col_sql = ", ".join(f'"{c}" {t}' for c, t in wanted)
                    cur.execute(f'CREATE TABLE {target_schema}."{tbl}" ({col_sql})')

                csv_path = Path(tmp) / f"{tbl}.csv"
                duck.execute(f"COPY (SELECT * FROM {source_schema}.\"{tbl}\") "
                             f"TO '{csv_path.as_posix()}' (FORMAT csv, HEADER true)")
                cur.execute(f'TRUNCATE {target_schema}."{tbl}"')
                with open(csv_path, encoding="utf-8") as fh:
                    cur.copy_expert(f'COPY {target_schema}."{tbl}" FROM STDIN WITH (FORMAT csv, HEADER true)', fh)
                cur.execute(f'SELECT COUNT(*) FROM {target_schema}."{tbl}"')
                n = cur.fetchone()[0]
                results.append({"table": f"{target_schema}.{tbl}", "rows": n,
                                "seconds": round(time.time() - t0, 3)})
            # leaving the `with pg` block commits everything at once
        with pg, pg.cursor() as cur:
            for r in results:
                cur.execute(f"ANALYZE {r['table'].split('.')[0]}.\"{r['table'].split('.')[1]}\"")
    finally:
        pg.close()
        duck.close()
    return results


if __name__ == "__main__":
    out = publish()
    for r in out:
        print(f"{r['table']:<35} {r['rows']:>10,} rows  {r['seconds']:>7.3f} s")
    print(f"Published {len(out)} tables to Postgres schema '{TARGET_SCHEMA}'.")
