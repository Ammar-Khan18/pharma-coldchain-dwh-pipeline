"""
query_runner.py  —  Phase 1 query layer (WBS 3.4 / 2.6), Excel Star.Schema sheet.

Runs the business-widget SQL on the DuckDB SDI mart, times each execution in
milliseconds, and writes one row per execution to meta.query_log (so the
"query performance" dashboard shows base-vs-aggregate-vs-partitioned timings and
an error rate). Each widget has two variants that return the same result:
    base   sql/queries/<name>_base.sql   — scans the fact tables
    agg    sql/queries/<name>_agg.sql    — reads the pre-aggregate tables
and q1 additionally runs against the partitioned Parquet export for a single month
(logged as q1_channel_margin_partitioned).

Public functions (used by dags/sdi_query.py):
    build_aggregates(duck_path)                   run sql/mart/sdi_50_aggregates.sql (indexes + aggs)
    export_partitions(duck_path)                  write the Parquet partitions
    benchmark(duck_path, dsn, batch, reps=5)      run every query, both variants, reps times
    benchmark_partitioned(duck_path, dsn, batch)  time q1 against the partitions (single month)
    run_widgets_once(duck_path, dsn, batch)       run the agg widgets once (a refresh)
    run_injected_failure(duck_path, dsn, batch)   run one deliberately failing query

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

# The dashboard widgets, in display order. Each has a _base and an _agg SQL file.
QUERIES = [
    {"name": "q1_channel_margin",              "widget": "Channel margin by month"},
    {"name": "q2_hospital_forecast_vs_actual", "widget": "Hospital forecast vs actual"},
    {"name": "q3_top_bottom_by_state",         "widget": "Top / bottom medicines by state"},
]


def duckdb_path() -> Path:
    duck_dir = os.environ.get("DUCKDB_DIR", str(Path.home() / "pipeline" / "marts"))
    return Path(duck_dir) / "sdi_mart.duckdb"


def _partitions_dir(duck_path: Path) -> Path:
    return duck_path.parent / "partitions"


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


def _time_and_log(con, dsn: str, batch_id: str, widget: str, query_name: str,
                  sql: str, optimized: bool) -> dict:
    """Execute one SQL string once, time it in ms, and log it to meta.query_log."""
    t0 = time.perf_counter()
    status, rows, err = "SUCCESS", 0, None
    try:
        rows = len(con.execute(sql).fetchall())
    except Exception as exc:
        status, err = "FAILED", str(exc).splitlines()[0]
    row = {
        "etl_batch_id": batch_id, "dashboard": DASHBOARD, "widget": widget,
        "query_name": query_name, "optimized": optimized,
        "duration_ms": round((time.perf_counter() - t0) * 1000, 3),
        "rows_returned": rows, "status": status, "error_message": err,
    }
    _log_query(dsn, row)
    return row


def run_query(con, dsn: str, batch_id: str, spec: dict, variant: str) -> dict:
    """Run one widget query (variant 'base' or 'agg') once, time it, log it."""
    sql = (SQL_QUERIES / f"{spec['name']}_{variant}.sql").read_text(encoding="utf-8")
    return _time_and_log(con, dsn, batch_id, spec["widget"],
                         f"{spec['name']}_{variant}", sql, optimized=(variant != "base"))


# ---------------------------------------------------------------------------
# tasks
# ---------------------------------------------------------------------------
def build_aggregates(duck_path: Path | None = None) -> None:
    """(Re)build the fact indexes and the agg_ pre-aggregate tables."""
    con = duckdb.connect(str(duck_path or duckdb_path()))
    try:
        con.execute((SQL_MART / "sdi_50_aggregates.sql").read_text(encoding="utf-8"))
        built = con.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema='sdi' AND table_name LIKE 'agg_%' ORDER BY 1").fetchall()
    finally:
        con.close()
    print(f"build_aggregates: {[b[0] for b in built]}")


def export_partitions(duck_path: Path | None = None) -> dict:
    """Export the facts to Parquet, partitioned per the Excel Fact.Table sheet:
       FactPharmacySales  -> partitions/fact_pharmacy_sales/  PARTITION_BY (Year, Month)
       FactHospitalDemand -> partitions/fact_hospital_demand/ PARTITION_BY (Year)
    Year/Month are derived from DateKey. OVERWRITE_OR_IGNORE keeps it re-runnable."""
    duck_path = duck_path or duckdb_path()
    pdir = _partitions_dir(duck_path)
    pdir.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(duck_path), read_only=True)
    try:
        con.execute(
            "COPY (SELECT *, \"DateKey\" // 10000 AS \"Year\", (\"DateKey\" // 100) % 100 AS \"Month\" "
            "      FROM sdi.\"FactPharmacySales\") "
            f"TO '{(pdir / 'fact_pharmacy_sales').as_posix()}' "
            "(FORMAT parquet, PARTITION_BY (\"Year\", \"Month\"), OVERWRITE_OR_IGNORE)")
        con.execute(
            "COPY (SELECT *, \"DateKey\" // 10000 AS \"Year\" "
            "      FROM sdi.\"FactHospitalDemand\") "
            f"TO '{(pdir / 'fact_hospital_demand').as_posix()}' "
            "(FORMAT parquet, PARTITION_BY (\"Year\"), OVERWRITE_OR_IGNORE)")
    finally:
        con.close()
    print(f"export_partitions: wrote Parquet partitions under {pdir}")
    return {"partitions_dir": str(pdir)}


def benchmark(duck_path: Path | None = None, dsn: str = PG_DSN,
              batch_id: str = "manual", reps: int = 5) -> dict:
    """Run every widget query in both variants, `reps` times each, logging all."""
    con = duckdb.connect(str(duck_path or duckdb_path()), read_only=True)
    summary = {}
    try:
        for spec in QUERIES:
            for variant in ("base", "agg"):
                times = [run_query(con, dsn, batch_id, spec, variant)["duration_ms"]
                         for _ in range(reps)]
                summary[f"{spec['name']}_{variant}"] = round(sum(times) / len(times), 3)
    finally:
        con.close()
    print(f"benchmark: {reps} reps each; avg ms = {summary}")
    return summary


def benchmark_partitioned(duck_path: Path | None = None, dsn: str = PG_DSN,
                          batch_id: str = "manual", reps: int = 5) -> dict:
    """Time q1 (channel margin) for a SINGLE month against the partitioned Parquet
    files, logged as q1_channel_margin_partitioned. Reads only that month's
    partition directory (Year=/Month=), i.e. partition pruning in action."""
    duck_path = duck_path or duckdb_path()
    con = duckdb.connect(str(duck_path), read_only=True)
    try:
        mdk = con.execute('SELECT max("DateKey") FROM sdi."FactPharmacySales"').fetchone()[0]
        yr, mo = mdk // 10000, (mdk // 100) % 100

        # Fair comparison (decision H): the SAME single-month channel-margin query,
        # once against the FactPharmacySales table (filtered to the month), and once
        # against that month's Parquet partition. Timed identically.
        base_sql = (
            'SELECT p."SalesChannel", '
            '       sum(f."NetSales") AS net_sales, sum(f."COGS") AS cogs, '
            '       sum(f."GrossMargin") AS gross_margin, '
            '       sum(f."GrossMargin") / nullif(sum(f."NetSales"), 0) AS gross_margin_pct '
            'FROM sdi."FactPharmacySales" f '
            'JOIN sdi."DimPharmacy" p ON p."PharmacyKey" = f."PharmacyKey" '
            f'WHERE f."DateKey" BETWEEN {yr*10000 + mo*100 + 1} AND {yr*10000 + mo*100 + 31} '
            'GROUP BY p."SalesChannel" ORDER BY p."SalesChannel"')
        base_t = [_time_and_log(con, dsn, batch_id, QUERIES[0]["widget"],
                                "q1_channel_margin_month_base", base_sql, optimized=False)["duration_ms"]
                  for _ in range(reps)]

        # Point directly at the month's partition; reading the recursive glob and
        # filtering would open every partition's footer instead (much slower).
        one = (_partitions_dir(duck_path) / "fact_pharmacy_sales"
               / f"Year={yr}" / f"Month={mo}" / "*.parquet").as_posix()
        part_sql = (
            'SELECT p."SalesChannel", '
            '       sum(f."NetSales") AS net_sales, sum(f."COGS") AS cogs, '
            '       sum(f."GrossMargin") AS gross_margin, '
            '       sum(f."GrossMargin") / nullif(sum(f."NetSales"), 0) AS gross_margin_pct '
            f"FROM read_parquet('{one}', hive_partitioning = true) f "
            'JOIN sdi."DimPharmacy" p ON p."PharmacyKey" = f."PharmacyKey" '
            'GROUP BY p."SalesChannel" ORDER BY p."SalesChannel"')
        part_t = [_time_and_log(con, dsn, batch_id, QUERIES[0]["widget"],
                                "q1_channel_margin_partitioned", part_sql, optimized=True)["duration_ms"]
                  for _ in range(reps)]
    finally:
        con.close()
    out = {"month": f"{yr}-{mo:02d}",
           "q1_channel_margin_month_base": round(sum(base_t) / len(base_t), 3),
           "q1_channel_margin_partitioned": round(sum(part_t) / len(part_t), 3)}
    print(f"benchmark_partitioned ({out['month']}): table={out['q1_channel_margin_month_base']}ms "
          f"partition={out['q1_channel_margin_partitioned']}ms")
    return out


def run_widgets_once(duck_path: Path | None = None, dsn: str = PG_DSN,
                     batch_id: str = "manual") -> int:
    """Run each agg widget query once, as a dashboard refresh would."""
    con = duckdb.connect(str(duck_path or duckdb_path()), read_only=True)
    try:
        for spec in QUERIES:
            run_query(con, dsn, batch_id, spec, variant="agg")
    finally:
        con.close()
    print(f"run_widgets_once: refreshed {len(QUERIES)} widgets")
    return len(QUERIES)


def run_injected_failure(duck_path: Path | None = None, dsn: str = PG_DSN,
                         batch_id: str = "manual") -> dict:
    """Run one deliberately broken query so the error rate is non-zero on demand."""
    con = duckdb.connect(str(duck_path or duckdb_path()), read_only=True)
    try:
        row = _time_and_log(
            con, dsn, batch_id, "Injected failure (test)", "q99_injected_error",
            'SELECT this_column_does_not_exist FROM sdi."FactPharmacySales" LIMIT 1',
            optimized=False)
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
        export_partitions()
        b = "manual_" + time.strftime("%Y%m%dT%H%M%S")
        benchmark(batch_id=b)
        benchmark_partitioned(batch_id=b)
    elif cmd == "fail":
        run_injected_failure(batch_id="manual_fail")
