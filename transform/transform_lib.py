"""
transform_lib.py  —  helpers for the Phase 1 SDI transform (ODS -> DuckDB star -> mart).

WBS 3.x. Used by dags/sdi_transform.py. The heavy lifting lives in the numbered
SQL files under sql/mart/ (sdi_10_validate … sdi_40_tests); this module just:
  * opens the DuckDB mart file and ATTACHes Postgres (DuckDB postgres extension)
    read-only, so the transform reads ods.* fast without copying,
  * stamps the current transform etl_batch_id into stg._batch (the SQL files read
    it as `(SELECT etl_batch_id FROM stg._batch)`),
  * runs a .sql file (possibly many statements) against DuckDB,
  * ships the DuckDB validation staging tables (_rejected, _dq) into Postgres
    (ods.rejected_rows, meta.dq_log) with psycopg2 — Postgres writes stay in
    psycopg2, exactly like serving/publish_mart.py.

Why ATTACH read-only: every Postgres write in this layer goes through psycopg2
(rejected rows, dq log, pipeline_run) or through publish_mart.py, so DuckDB never
needs to write to Postgres. Reading is all it does, and read-only is safest.
"""
import os
from pathlib import Path

import duckdb
import psycopg2
from psycopg2.extras import execute_values

REPO_ROOT = Path(__file__).resolve().parents[1]
SQL_MART = REPO_ROOT / "sql" / "mart"
SQL_PG = REPO_ROOT / "sql" / "postgres"

PG_DSN = os.environ.get(
    "IDA_PG_DSN",
    "host=localhost port=5432 dbname=ida_staging user=ida_user password=ida_pass",
)


def duckdb_path() -> Path:
    """The DuckDB mart file: <DUCKDB_DIR>/sdi_mart.duckdb (DUCKDB_DIR or a default)."""
    duck_dir = os.environ.get("DUCKDB_DIR", str(Path.home() / "pipeline" / "marts"))
    return Path(duck_dir) / "sdi_mart.duckdb"


# ---------------------------------------------------------------------------
# DuckDB
# ---------------------------------------------------------------------------
def open_duck(pg_dsn: str = PG_DSN, duck_path: Path | None = None):
    """Open the DuckDB mart with Postgres attached as `pg` (read-only)."""
    con = duckdb.connect(str(duck_path or duckdb_path()))
    con.execute("INSTALL postgres; LOAD postgres;")
    con.execute(f"ATTACH '{pg_dsn}' AS pg (TYPE postgres, READ_ONLY)")
    return con


def stamp_batch(con, etl_batch_id: str) -> None:
    """Record the transform run id so the SQL files can read it.

    Staging tables live in schema `stg` (not `sdi`) so publish_mart.py — which
    copies every base table in schema `sdi` — never sees them.
    """
    con.execute("CREATE SCHEMA IF NOT EXISTS sdi")
    con.execute("CREATE SCHEMA IF NOT EXISTS stg")
    con.execute(
        "CREATE OR REPLACE TABLE stg._batch AS "
        "SELECT ?::VARCHAR AS etl_batch_id, now() AS run_ts, current_date AS run_date",
        [etl_batch_id],
    )


def run_sql_file(con, path) -> None:
    """Execute every statement in a .sql file against DuckDB."""
    con.execute(Path(path).read_text(encoding="utf-8"))


def run_sql_files(con, names) -> None:
    for n in names:
        run_sql_file(con, SQL_MART / n)


# ---------------------------------------------------------------------------
# Postgres (psycopg2) — ship DuckDB staging tables out, and small helpers
# ---------------------------------------------------------------------------
def ensure_rejected_table(pg_dsn: str = PG_DSN) -> None:
    """Create ods.rejected_rows if missing (idempotent)."""
    with psycopg2.connect(pg_dsn) as conn, conn.cursor() as cur:
        cur.execute((SQL_PG / "03_rejected_rows.sql").read_text(encoding="utf-8"))


def push_rejected(con, pg_dsn: str = PG_DSN) -> int:
    """Copy DuckDB stg._rejected into Postgres ods.rejected_rows. Returns rows written."""
    rows = con.execute(
        "SELECT source_table, natural_key, rule_id, reason, raw_row, etl_batch_id "
        "FROM stg._rejected"
    ).fetchall()
    if not rows:
        return 0
    with psycopg2.connect(pg_dsn) as conn, conn.cursor() as cur:
        execute_values(
            cur,
            "INSERT INTO ods.rejected_rows "
            "(source_table, natural_key, rule_id, reason, raw_row, etl_batch_id) "
            "VALUES %s",
            rows,
            template="(%s, %s, %s, %s, %s::jsonb, %s)",
        )
    return len(rows)


def push_dq_log(con, pg_dsn: str = PG_DSN) -> int:
    """Copy DuckDB stg._dq into Postgres meta.dq_log. Returns rows written."""
    rows = con.execute(
        "SELECT etl_batch_id, source_file, rule_id, rule_action, rows_checked, rows_failed "
        "FROM stg._dq ORDER BY rule_id"
    ).fetchall()
    if not rows:
        return 0
    with psycopg2.connect(pg_dsn) as conn, conn.cursor() as cur:
        execute_values(
            cur,
            "INSERT INTO meta.dq_log "
            "(etl_batch_id, source_file, rule_id, rule_action, rows_checked, rows_failed) "
            "VALUES %s",
            rows,
        )
    return len(rows)
