"""
sdi_transform  —  Phase 1 transform DAG (Postgres ODS -> DuckDB star -> Postgres mart).

WBS 3.x. Builds the SDI star schema in DuckDB from the ODS tables, runs data
tests, then publishes the mart to Postgres for Power BI. The step logic lives in
sql/mart/sdi_10_validate … sdi_40_tests (run through transform/transform_lib.py);
this DAG keeps one task per step.

Flow:
    start_run -> validate -> build_dims -> build_facts -> data_tests -> publish_mart
                                                                           |
                                                      finish_success / finish_failed

    start_run      open a meta.pipeline_run row and mint the transform etl_batch_id.
    validate       apply the REJECT/WARN rules; stage clean rows; write rejected
                   rows to ods.rejected_rows and per-rule counts to meta.dq_log.
    build_dims     SCD2 dim_medicine; SCD1 dim_pharmacy/dim_hospital; junk dims.
    build_facts    append fact_sales and fact_hospital_demand (skip existing keys).
    data_tests     unique keys, no NULL FKs, FK-in-dim, row-count reconciliation;
                   FAILS the task (and the run) if any test fails.
    publish_mart   serving/publish_mart.py copies schema sdi -> Postgres schema mart.
    finish_*       close the pipeline_run row SUCCESS or FAILED.

Automation: scheduled on the Asset that sdi_ingest produces on success, so a
successful ingest run triggers this DAG automatically (no manual step). It can
also be triggered by hand. retries=2. Nothing here changes the mart design or
publish_mart.py.
"""
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg2
from airflow.sdk import Asset, Connection, Variable, dag, get_current_context, task

REPO_ROOT = Path(__file__).resolve().parents[1]
for sub in ("transform", "serving"):
    p = str(REPO_ROOT / sub)
    if p not in sys.path:
        sys.path.insert(0, p)

import transform_lib as T   # noqa: E402
import publish_mart          # noqa: E402  (serving/publish_mart.py — not modified)

DAG_ID = "sdi_transform"
PHASE = "P1_SDI"

# Same Asset identity as the one sdi_ingest produces (matched by name/uri).
SDI_ODS_ASSET = Asset(name="sdi_ods_loaded", uri="sdi://ods/phase1")
# Produced when the mart is published; the query + storage DAGs schedule on it.
SDI_MART_ASSET = Asset(name="sdi_mart_published", uri="sdi://mart/phase1")

default_args = {"owner": "ida", "retries": 2, "retry_delay": timedelta(minutes=1)}


# --- runtime helpers (resolved inside tasks) -------------------------------
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


def _run_duck(etl_batch_id: str, sql_files: list[str]):
    """Open the DuckDB mart (Postgres attached), stamp the batch, run SQL files.
    Returns the open connection so the caller can read staging tables, then close."""
    con = T.open_duck(pg_dsn=_pg_dsn(), duck_path=_duck_path())
    T.stamp_batch(con, etl_batch_id)
    return con


@dag(
    dag_id=DAG_ID,
    start_date=datetime(2026, 11, 1),
    schedule=[SDI_ODS_ASSET],          # auto-runs after a successful sdi_ingest
    catchup=False,
    default_args=default_args,
    tags=["phase1", "sdi", "transform", "mart"],
)
def sdi_transform():

    @task
    def start_run() -> str:
        ctx = get_current_context()
        dag_run = ctx["dag_run"]
        conf = dag_run.conf or {}
        etl_batch_id = "sdt_" + datetime.now().strftime("%Y%m%dT%H%M%S")
        refresh_label = conf.get("refresh_label", "transform")
        T.ensure_rejected_table(_pg_dsn())          # ods.rejected_rows if missing
        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO meta.pipeline_run "
                "(etl_batch_id, dag_id, run_id, phase, refresh_label, started_at, status) "
                "VALUES (%s, %s, %s, %s, %s, %s, 'RUNNING')",
                (etl_batch_id, DAG_ID, dag_run.run_id, PHASE, refresh_label,
                 datetime.now(timezone.utc)),
            )
        print(f"start_run: etl_batch_id={etl_batch_id}")
        return etl_batch_id

    @task
    def validate(etl_batch_id: str) -> dict:
        con = _run_duck(etl_batch_id, [])
        try:
            T.run_sql_file(con, T.SQL_MART / "sdi_01_create_schema.sql")   # ensure mart tables/seeds
            T.run_sql_file(con, T.SQL_MART / "sdi_10_validate.sql")
            recon = con.execute(
                "SELECT source_table, attempted_new, rejected_cnt, clean_cnt "
                "FROM stg._recon ORDER BY source_table").fetchall()
            rejected_n = T.push_rejected(con, _pg_dsn())
            dq_n = T.push_dq_log(con, _pg_dsn())
        finally:
            con.close()
        result = {"recon": recon, "rejected_rows": rejected_n, "dq_rules_logged": dq_n}
        print(f"validate: {result}")
        return result

    @task
    def build_dims(etl_batch_id: str) -> None:
        con = _run_duck(etl_batch_id, [])
        try:
            T.run_sql_file(con, T.SQL_MART / "sdi_20_dims.sql")
        finally:
            con.close()
        print("build_dims: dimensions upserted")

    @task
    def build_facts(etl_batch_id: str) -> None:
        con = _run_duck(etl_batch_id, [])
        try:
            T.run_sql_file(con, T.SQL_MART / "sdi_30_facts.sql")
        finally:
            con.close()
        print("build_facts: facts appended")

    @task
    def data_tests(etl_batch_id: str) -> None:
        con = _run_duck(etl_batch_id, [])
        try:
            T.run_sql_file(con, T.SQL_MART / "sdi_40_tests.sql")
            rows = con.execute(
                "SELECT test_name, passed, detail FROM stg._test_results ORDER BY test_name"
            ).fetchall()
        finally:
            con.close()
        for name, passed, detail in rows:
            print(f"  [{'PASS' if passed else 'FAIL'}] {name}: {detail}")
        failed = [r[0] for r in rows if not r[1]]
        if failed:
            raise ValueError(f"data tests failed: {failed}")
        print(f"data_tests: all {len(rows)} tests passed")

    @task
    def publish_to_mart() -> list:
        out = publish_mart.publish(duckdb_path=_duck_path(), pg_dsn=_pg_dsn())
        for r in out:
            print(f"  published {r['table']:<30} {r['rows']:>10,} rows")
        return out

    def _close_run(etl_batch_id: str, status: str) -> None:
        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM mart.fact_sales")
            fs = cur.fetchone()[0]
            cur.execute("SELECT count(*) FROM mart.fact_hospital_demand")
            fh = cur.fetchone()[0]
            notes = f"{status.lower()}; mart.fact_sales={fs}, mart.fact_hospital_demand={fh}"
            cur.execute(
                "UPDATE meta.pipeline_run SET finished_at = %s, status = %s, notes = %s "
                "WHERE etl_batch_id = %s",
                (datetime.now(timezone.utc), status, notes, etl_batch_id),
            )
        print(f"finish: {status} ({notes})")

    @task(trigger_rule="all_success", outlets=[SDI_MART_ASSET])
    def finish_success(etl_batch_id: str) -> None:
        _close_run(etl_batch_id, "SUCCESS")
        print(f"finish_success: producing Asset {SDI_MART_ASSET.uri} "
              f"-> sdi_query and sdi_storage_metrics will be triggered.")

    @task(trigger_rule="one_failed")
    def finish_failed(etl_batch_id: str) -> None:
        # mart counts may be stale/partial on failure; still record FAILED.
        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute(
                "UPDATE meta.pipeline_run SET finished_at = %s, status = 'FAILED', "
                "notes = 'transform failed; see task logs' WHERE etl_batch_id = %s",
                (datetime.now(timezone.utc), etl_batch_id),
            )
        print("finish: FAILED")

    batch_id = start_run()
    v = validate(batch_id)
    d = build_dims(batch_id)
    f = build_facts(batch_id)
    t = data_tests(batch_id)
    p = publish_to_mart()
    ok = finish_success(batch_id)
    bad = finish_failed(batch_id)

    batch_id >> v >> d >> f >> t >> p >> ok
    # failure anywhere in the chain closes the run as FAILED
    [v, d, f, t, p] >> bad


sdi_transform()
