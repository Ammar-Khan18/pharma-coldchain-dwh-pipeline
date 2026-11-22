"""
sdi_query  —  Phase 1 query layer + benchmark DAG (WBS 3.4 / 2.6).

Builds the pre-aggregate tables, benchmarks every dashboard widget query in both
the raw (fact-scan) and optimized (pre-aggregate) variants, simulates a dashboard
refresh, and publishes the aggregates to the Postgres mart for Power BI. Every
query execution is timed and written to meta.query_log.

Flow:
    start_run -> build_aggregates -> export_partitions -> benchmark
              -> benchmark_partitioned -> simulate_dashboard_refresh
              -> inject_error_test -> publish_aggregates -> finish_*

    start_run                 apply the small meta migration; open a pipeline_run row.
    build_aggregates          build fact indexes + agg_ tables (sql/mart/sdi_50_aggregates.sql).
    export_partitions         export the facts to Parquet (Year/Month, Year) partitions.
    benchmark                 run all 3 widgets x {base, agg} x 5 reps, logging each.
    benchmark_partitioned     time q1 for one month against the Parquet partitions.
    simulate_dashboard_refresh run the 3 agg widgets once, as a dashboard would.
    inject_error_test         optional: with conf {"inject_error": true} run one
                              deliberately failing query so the error rate is non-zero.
    publish_aggregates        publish_mart.py copies sdi (incl. agg_) -> Postgres mart.
    finish_*                  close the pipeline_run row SUCCESS / FAILED.

Automation: scheduled on the Asset sdi_transform produces, so it runs after each
successful transform. retries=2.
"""
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg2
from airflow.sdk import Asset, Connection, Variable, dag, get_current_context, task

REPO_ROOT = Path(__file__).resolve().parents[1]
for sub in ("query", "serving"):
    p = str(REPO_ROOT / sub)
    if p not in sys.path:
        sys.path.insert(0, p)

import query_runner as QR   # noqa: E402
import publish_mart          # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))   # dags dir, for ida_dag_utils
from ida_dag_utils import pipeline_run_failure  # noqa: E402

DAG_ID = "sdi_query"
PHASE = "P1_SDI"
BENCHMARK_REPS = 5
SDI_MART_ASSET = Asset(name="sdi_mart_published", uri="sdi://mart/phase1")
MIGRATION_SQL = REPO_ROOT / "sql" / "postgres" / "04_query_storage_meta.sql"

default_args = {"owner": "ida", "retries": 2, "retry_delay": timedelta(minutes=1),
                "on_failure_callback": pipeline_run_failure,
                "execution_timeout": timedelta(minutes=30)}   # guards benchmark/publish


def _pg_dsn() -> str:
    c = Connection.get("ida_postgres")
    return (f"host={c.host} port={c.port or 5432} dbname={c.schema} "
            f"user={c.login} password={c.password}")


def _duck_path() -> Path:
    try:
        d = Variable.get("DUCKDB_DIR")
    except Exception:
        d = None
    return Path(d or (Path.home() / "pipeline" / "marts")) / "sdi_mart.duckdb"


@dag(
    dag_id=DAG_ID,
    start_date=datetime(2026, 11, 1),
    schedule=[SDI_MART_ASSET],
    catchup=False,
    default_args=default_args,
    tags=["phase1", "sdi", "query", "benchmark"],
)
def sdi_query():

    @task
    def start_run() -> str:
        ctx = get_current_context()
        dag_run = ctx["dag_run"]
        etl_batch_id = "sdq_" + datetime.now().strftime("%Y%m%dT%H%M%S")
        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute(MIGRATION_SQL.read_text(encoding="utf-8"))   # idempotent
            cur.execute(
                "INSERT INTO meta.pipeline_run "
                "(etl_batch_id, dag_id, run_id, phase, refresh_label, started_at, status) "
                "VALUES (%s, %s, %s, %s, 'query', %s, 'RUNNING')",
                (etl_batch_id, DAG_ID, dag_run.run_id, PHASE, datetime.now(timezone.utc)),
            )
        print(f"start_run: etl_batch_id={etl_batch_id}")
        return etl_batch_id

    @task
    def build_aggregates(etl_batch_id: str) -> None:
        QR.build_aggregates(_duck_path())

    @task
    def export_partitions(etl_batch_id: str) -> dict:
        return QR.export_partitions(_duck_path())

    @task
    def benchmark(etl_batch_id: str) -> dict:
        return QR.benchmark(_duck_path(), _pg_dsn(), etl_batch_id, reps=BENCHMARK_REPS)

    @task
    def benchmark_partitioned(etl_batch_id: str) -> dict:
        return QR.benchmark_partitioned(_duck_path(), _pg_dsn(), etl_batch_id, reps=BENCHMARK_REPS)

    @task
    def simulate_dashboard_refresh(etl_batch_id: str) -> int:
        return QR.run_widgets_once(_duck_path(), _pg_dsn(), etl_batch_id)

    @task
    def inject_error_test(etl_batch_id: str) -> str:
        """Optional: only runs the failing query when triggered with
        conf {"inject_error": true}; otherwise it is a no-op."""
        ctx = get_current_context()
        if (ctx["dag_run"].conf or {}).get("inject_error"):
            QR.run_injected_failure(_duck_path(), _pg_dsn(), etl_batch_id)
            return "injected"
        print("inject_error_test: skipped (pass conf {\"inject_error\": true} to enable)")
        return "skipped"

    @task
    def publish_aggregates(etl_batch_id: str) -> list:
        out = publish_mart.publish(duckdb_path=_duck_path(), pg_dsn=_pg_dsn())
        aggs = [r for r in out if r["table"].split(".")[-1].startswith("agg_")]
        print(f"publish_aggregates: {len(out)} tables published; aggregates: {aggs}")
        return aggs

    def _close_run(etl_batch_id: str, status: str, notes: str) -> None:
        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute(
                "UPDATE meta.pipeline_run SET finished_at = %s, status = %s, notes = %s "
                "WHERE etl_batch_id = %s",
                (datetime.now(timezone.utc), status, notes, etl_batch_id))
        print(f"finish: {status} ({notes})")

    @task(trigger_rule="all_success")
    def finish_success(etl_batch_id: str) -> None:
        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute("SELECT count(*), count(*) FILTER (WHERE status='FAILED') "
                        "FROM meta.query_log WHERE etl_batch_id=%s", (etl_batch_id,))
            total, failed = cur.fetchone()
        _close_run(etl_batch_id, "SUCCESS",
                   f"query_log rows={total}, failed={failed}")

    @task(trigger_rule="one_failed")
    def finish_failed(etl_batch_id: str) -> None:
        _close_run(etl_batch_id, "FAILED", "query layer failed; see task logs")

    b = start_run()
    agg = build_aggregates(b)
    part = export_partitions(b)
    bench = benchmark(b)
    benchp = benchmark_partitioned(b)
    sim = simulate_dashboard_refresh(b)
    inj = inject_error_test(b)
    pub = publish_aggregates(b)
    ok = finish_success(b)
    bad = finish_failed(b)

    agg >> part >> bench >> benchp >> sim >> inj >> pub >> ok
    [agg, part, bench, benchp, sim, inj, pub] >> bad


sdi_query()
