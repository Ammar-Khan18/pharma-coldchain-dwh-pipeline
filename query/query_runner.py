"""
query_runner.py  —  Phase 1 query layer (WBS 3.4 / 2.6).

Runs the business-widget SQL on the DuckDB SDI mart, times each execution in
milliseconds, and writes one row per execution to meta.query_log (so the
"query performance" dashboard can show raw-vs-optimized timings and an error
rate). Each widget has two variants:
    raw        sql/queries/<name>.sql       — scans the fact tables
    optimized  sql/queries/<name>_opt.sql   — reads the agg_ pre-aggregates

Public functions (used by dags/sdi_query.py):
    build_aggregates(duck_path)                 run sql/mart/sdi_50_aggregates.sql
    benchmark(duck_path, dsn, batch, reps=5)    run every query, both variants, reps times
    run_widgets_once(duck_path, dsn, batch)     run the optimized widgets once (a refresh)
    run_injected_failure(duck_path, dsn, batch) run one deliberately failing query

Standalone:
    python query/query_runner.py benchmark
"""
import os
import sys
import time
from pathlib import Path

import duckdb
import psycopg2

REPO_ROOT = Path(__file__).resolve().parents[1]
SQL_QUERIES = REPO_ROOT / "sql" / "queries"
SQL_MART = REPO_ROOT / "sql" / "mart"

PG_DSN = os.environ.get(
    "IDA_PG_DSN",
    "host=localhost port=5432 dbname=ida_staging user=ida_user password=ida_pass",
)
DASHBOARD = "SDI"

# The dashboard widgets, in display order. Each has a raw and an _opt SQL file.
QUERIES = [
    {"name": "q01_channel_revenue_margin",   "widget": "Channel revenue & margin by month"},
    {"name": "q02_hospital_forecast_vs_actual", "widget": "Hospital forecast vs actual"},
    {"name": "q03_top10_fast_slow_movers",   "widget": "Top / bottom 10 movers"},
    {"name": "q04_kpi_total_revenue",        "widget": "KPI: total revenue (latest month)"},
    {"name": "q05_kpi_total_units",          "widget": "KPI: units sold (latest month)"},
    {"name": "q06_kpi_margin_pct",           "widget": "KPI: margin % (latest month)"},
]


def duckdb_path() -> Path:
    duck_dir = os.environ.get("DUCKDB_DIR", str(Path.home() / "pipeline" / "marts"))
    return Path(duck_dir) / "sdi_mart.duckdb"


def _sql_path(name: str, optimized: bool) -> Path:
    return SQL_QUERIES / (f"{name}_opt.sql" if optimized else f"{name}.sql")


def _log_query(dsn: str, row: dict) -> None:
    with psycopg2.connect(dsn) as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO meta.query_log "
            "(etl_batch_id, engine, dashboard, widget, query_name, optimized, "
            " duration_ms, rows_returned, status, error_message) "
            "VALUES (%(etl_batch_id)s, 'duckdb', %(dashboard)s, %(widget)s, %(query_name)s, "
            "        %(optimized)s, %(duration_ms)s, %(rows_returned)s, %(status)s, %(error_message)s)",
            row,
        )


def run_query(con, dsn: str, batch_id: str, spec: dict, optimized: bool) -> dict:
    """Run one widget query once, time it, log it. Returns the log row."""
    sql = _sql_path(spec["name"], optimized).read_text(encoding="utf-8")
    t0 = time.perf_counter()
    status, rows, err = "SUCCESS", 0, None
    try:
        rows = len(con.execute(sql).fetchall())
    except Exception as exc:
        status, err = "FAILED", str(exc)
    duration_ms = round((time.perf_counter() - t0) * 1000, 3)
    row = {
        "etl_batch_id": batch_id, "dashboard": DASHBOARD, "widget": spec["widget"],
        "query_name": spec["name"], "optimized": optimized, "duration_ms": duration_ms,
        "rows_returned": rows, "status": status, "error_message": err,
    }
    _log_query(dsn, row)
    return row


# ---------------------------------------------------------------------------
# tasks
# ---------------------------------------------------------------------------
def build_aggregates(duck_path: Path | None = None) -> None:
    """(Re)build the agg_ pre-aggregate tables in the DuckDB mart."""
    con = duckdb.connect(str(duck_path or duckdb_path()))
    try:
        con.execute((SQL_MART / "sdi_50_aggregates.sql").read_text(encoding="utf-8"))
        built = con.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema='sdi' AND table_name LIKE 'agg_%' ORDER BY 1").fetchall()
    finally:
        con.close()
    print(f"build_aggregates: {[b[0] for b in built]}")


def benchmark(duck_path: Path | None = None, dsn: str = PG_DSN,
              batch_id: str = "manual", reps: int = 5) -> dict:
    """Run every widget query in both variants, `reps` times each, logging all."""
    con = duckdb.connect(str(duck_path or duckdb_path()), read_only=True)
    summary = {}
    try:
        for spec in QUERIES:
            for optimized in (False, True):
                times = []
                for _ in range(reps):
                    r = run_query(con, dsn, batch_id, spec, optimized)
                    times.append(r["duration_ms"])
                key = f"{spec['name']}:{'opt' if optimized else 'raw'}"
                summary[key] = round(sum(times) / len(times), 3)
    finally:
        con.close()
    print(f"benchmark: {reps} reps each; avg ms = {summary}")
    return summary


def run_widgets_once(duck_path: Path | None = None, dsn: str = PG_DSN,
                     batch_id: str = "manual") -> int:
    """Run each optimized widget query once, as a dashboard refresh would."""
    con = duckdb.connect(str(duck_path or duckdb_path()), read_only=True)
    try:
        for spec in QUERIES:
            run_query(con, dsn, batch_id, spec, optimized=True)
    finally:
        con.close()
    print(f"run_widgets_once: refreshed {len(QUERIES)} widgets")
    return len(QUERIES)


def run_injected_failure(duck_path: Path | None = None, dsn: str = PG_DSN,
                         batch_id: str = "manual") -> dict:
    """Run one deliberately broken query so the error rate is non-zero on demand."""
    con = duckdb.connect(str(duck_path or duckdb_path()), read_only=True)
    try:
        spec = {"name": "q99_injected_error", "widget": "Injected failure (test)"}
        # a query that references a column that does not exist -> FAILED
        t0 = time.perf_counter()
        status, rows, err = "SUCCESS", 0, None
        try:
            rows = len(con.execute(
                "SELECT this_column_does_not_exist FROM sdi.fact_sales LIMIT 1").fetchall())
        except Exception as exc:
            status, err = "FAILED", str(exc).splitlines()[0]
        row = {
            "etl_batch_id": batch_id, "dashboard": DASHBOARD, "widget": spec["widget"],
            "query_name": spec["name"], "optimized": False,
            "duration_ms": round((time.perf_counter() - t0) * 1000, 3),
            "rows_returned": rows, "status": status, "error_message": err,
        }
        _log_query(dsn, row)
    finally:
        con.close()
    print(f"run_injected_failure: logged {row['status']}")
    return row


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "benchmark"
    if cmd == "aggregates":
        build_aggregates()
    elif cmd == "benchmark":
        build_aggregates()
        benchmark(batch_id="manual_" + time.strftime("%Y%m%dT%H%M%S"))
    elif cmd == "fail":
        run_injected_failure(batch_id="manual_fail")
