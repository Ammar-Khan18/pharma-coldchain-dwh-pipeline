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

# The Power BI views (sql/postgres/07_bi_views.sql) sit on top of the mart tables
# this script refreshes. A mart table that changes columns is DROP+recreated below,
# which Postgres refuses while a view depends on it — so we drop every mart view
# before touching the tables, then re-run this file (idempotent CREATE + GRANT) in
# the same transaction, so Power BI always sees fresh views over fresh data.
BI_VIEWS_SQL = Path(__file__).resolve().parent.parent / "sql" / "postgres" / "07_bi_views.sql"


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
    # Do NOT publish the seed_* lookup tables to the serving layer.
    tables = [t for t in tables if not t.startswith("seed_")]
    if not tables:
        sys.exit(f"No tables in DuckDB schema '{source_schema}' ({duckdb_path}). Run the schema DDL first.")

    pg = psycopg2.connect(pg_dsn)
    results = []
    try:
        with pg, pg.cursor() as cur, tempfile.TemporaryDirectory() as tmp:
            # Drop the BI views first: they depend on the mart tables, and the
            # DROP TABLE below (for a changed column list) would fail otherwise.
            # They are recreated from BI_VIEWS_SQL after the tables are refreshed.
            cur.execute("SELECT table_name FROM information_schema.views "
                        "WHERE table_schema = %s", (target_schema,))
            for (view,) in cur.fetchall():
                cur.execute(f'DROP VIEW IF EXISTS {target_schema}."{view}" CASCADE')
            # Drop any mart table that no longer exists in the DuckDB mart (old
            # lowercase fact_sales / dim_channel / … and any un-published seed_*),
            # in the SAME transaction as the republish, so Power BI never sees them.
            cur.execute("SELECT table_name FROM information_schema.tables "
                        "WHERE table_schema = %s AND table_type = 'BASE TABLE'", (target_schema,))
            keep = set(tables)
            for (stale,) in [r for r in cur.fetchall() if r[0] not in keep]:
                cur.execute(f'DROP TABLE IF EXISTS {target_schema}."{stale}" CASCADE')
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
            # Re-apply read-only grants so bi_reader (Power BI / Grafana) can SELECT
            # every mart table, including any just (re)created. Same transaction.
            cur.execute(f"GRANT USAGE ON SCHEMA {target_schema} TO bi_reader")
            cur.execute(f"GRANT SELECT ON ALL TABLES IN SCHEMA {target_schema} TO bi_reader")
            # Recreate the Power BI views over the freshly-published tables (same
            # transaction, so Power BI never sees tables without their views). The
            # file is idempotent (DROP VIEW IF EXISTS ... CREATE ... GRANT).
            if BI_VIEWS_SQL.exists():
                cur.execute(BI_VIEWS_SQL.read_text(encoding="utf-8"))
            else:
                print(f"WARNING: {BI_VIEWS_SQL} not found; BI views NOT recreated.",
                      file=sys.stderr)
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
