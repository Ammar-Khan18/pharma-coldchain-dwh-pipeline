"""
sdi_transform  —  Phase 1 transform DAG (Postgres ODS -> DuckDB star -> Postgres mart).

WBS 3.x. Builds the Excel-aligned SDI star schema in DuckDB from the ODS tables,
runs data tests, then publishes the mart to Postgres for Power BI. The step logic
lives in the numbered SQL files under sql/mart/ (sdi_10_validate … sdi_40_tests,
run through transform/transform_lib.py); this DAG keeps ONE TASK PER STEP:

Flow:
    start_run -> validate
              -> build_dim_date -> build_dim_medicine -> build_dim_location
              -> build_dim_pharmacy -> build_dim_hospital
              -> build_fact_sales -> build_fact_demand
              -> data_tests -> publish_mart -> finish_success / finish_failed

Tasks run sequentially (DuckDB is single-writer, one connection at a time).
Dimensions precede facts; DimLocation precedes the pharmacy/hospital dims (LocationKey);
DimMedicine precedes the facts (point-in-time SCD2 key).

Seeds: every DuckDB connection SET VARIABLE seed_dir to $HOME/pipeline/sql/seeds
(expanded, no hard-coded username) so sdi_01 / dim steps can read sql/seeds/*.csv.

Automation: scheduled on the Asset sdi_ingest produces on success. retries=2.
"""
import os
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

sys.path.insert(0, str(Path(__file__).resolve().parent))   # dags dir, for ida_dag_utils
from ida_dag_utils import pipeline_run_failure  # noqa: E402

DAG_ID = "sdi_transform"
PHASE = "P1_SDI"

# Absolute seed directory ($HOME/pipeline/sql/seeds); no hard-coded username.
SEED_DIR = Path(os.environ.get("IDA_SEED_DIR", Path.home() / "pipeline" / "sql" / "seeds"))

SDI_ODS_ASSET = Asset(name="sdi_ods_loaded", uri="sdi://ods/phase1")
SDI_MART_ASSET = Asset(name="sdi_mart_published", uri="sdi://mart/phase1")

default_args = {"owner": "ida", "retries": 2, "retry_delay": timedelta(minutes=1),
                "on_failure_callback": pipeline_run_failure,
                "execution_timeout": timedelta(minutes=30)}


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


def _open(etl_batch_id: str):
    """Open the DuckDB mart (Postgres attached), set seed_dir, stamp the batch.
    Returns the open connection; the caller runs SQL files and closes it."""
    con = T.open_duck(pg_dsn=_pg_dsn(), duck_path=_duck_path())
    con.execute("SET VARIABLE seed_dir = ?", [str(SEED_DIR)])
    T.stamp_batch(con, etl_batch_id)
    return con


def _run(etl_batch_id: str, sql_file: str) -> None:
    con = _open(etl_batch_id)
    try:
        T.run_sql_file(con, T.SQL_MART / sql_file)
    finally:
        con.close()


@dag(
    dag_id=DAG_ID,
    start_date=datetime(2026, 11, 1),
    schedule=[SDI_ODS_ASSET],
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
        T.ensure_rejected_table(_pg_dsn())
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
        con = _open(etl_batch_id)
        try:
            T.run_sql_file(con, T.SQL_MART / "sdi_01_create_schema.sql")  # ensure tables + seeds
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
    def build_dim_date(etl_batch_id: str) -> None:
        _run(etl_batch_id, "sdi_21_dim_date.sql"); print("build_dim_date: done")

    @task
    def build_dim_medicine(etl_batch_id: str) -> None:
        _run(etl_batch_id, "sdi_22_dim_medicine.sql"); print("build_dim_medicine: SCD2 upserted")

    @task
    def build_dim_location(etl_batch_id: str) -> None:
        _run(etl_batch_id, "sdi_23_dim_location.sql"); print("build_dim_location: done")

    @task
    def build_dim_pharmacy(etl_batch_id: str) -> None:
        _run(etl_batch_id, "sdi_24_dim_pharmacy.sql"); print("build_dim_pharmacy: done")

    @task
    def build_dim_hospital(etl_batch_id: str) -> None:
        _run(etl_batch_id, "sdi_25_dim_hospital.sql"); print("build_dim_hospital: done")

    @task
    def build_fact_sales(etl_batch_id: str) -> None:
        _run(etl_batch_id, "sdi_31_fact_sales.sql"); print("build_fact_sales: appended")

    @task
    def build_fact_demand(etl_batch_id: str) -> None:
        _run(etl_batch_id, "sdi_32_fact_demand.sql"); print("build_fact_demand: appended")

    @task
    def data_tests(etl_batch_id: str) -> None:
        con = _open(etl_batch_id)
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
    def checkpoint_duck(etl_batch_id: str) -> None:
        """CHECKPOINT the DuckDB mart so the WAL is folded into the main file at the
        end of every transform (keeps the file consolidated between runs)."""
        con = _open(etl_batch_id)
        try:
            con.execute("CHECKPOINT")
        finally:
            con.close()
        print("checkpoint_duck: DuckDB checkpointed")

    @task
    def publish_to_mart() -> list:
        out = publish_mart.publish(duckdb_path=_duck_path(), pg_dsn=_pg_dsn())
        for r in out:
            print(f"  published {r['table']:<30} {r['rows']:>10,} rows")
        return out

    def _close_run(etl_batch_id: str, status: str) -> None:
        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute('SELECT count(*) FROM mart."FactPharmacySales"')
            fs = cur.fetchone()[0]
            cur.execute('SELECT count(*) FROM mart."FactHospitalDemand"')
            fh = cur.fetchone()[0]
            notes = f'{status.lower()}; mart.FactPharmacySales={fs}, mart.FactHospitalDemand={fh}'
            cur.execute(
                "UPDATE meta.pipeline_run SET finished_at = %s, status = %s, notes = %s "
                "WHERE etl_batch_id = %s",
                (datetime.now(timezone.utc), status, notes, etl_batch_id),
            )
        print(f"finish: {status} ({notes})")

    @task(trigger_rule="all_success", outlets=[SDI_MART_ASSET])
    def finish_success(etl_batch_id: str) -> None:
        _close_run(etl_batch_id, "SUCCESS")
        print(f"finish_success: producing Asset {SDI_MART_ASSET.uri}")

    @task(trigger_rule="one_failed")
    def finish_failed(etl_batch_id: str) -> None:
        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute(
                "UPDATE meta.pipeline_run SET finished_at = %s, status = 'FAILED', "
                "notes = 'transform failed; see task logs' WHERE etl_batch_id = %s",
                (datetime.now(timezone.utc), etl_batch_id),
            )
        print("finish: FAILED")

    b = start_run()
    v = validate(b)
    dd = build_dim_date(b)
    dm = build_dim_medicine(b)
    dl = build_dim_location(b)
    dp = build_dim_pharmacy(b)
    dh = build_dim_hospital(b)
    fs = build_fact_sales(b)
    fd = build_fact_demand(b)
    t = data_tests(b)
    cp = checkpoint_duck(b)
    p = publish_to_mart()
    ok = finish_success(b)
    bad = finish_failed(b)

    # Sequential chain (single DuckDB writer); dims before facts, location before
    # pharmacy/hospital, medicine before facts; checkpoint before publish.
    b >> v >> dd >> dm >> dl >> dp >> dh >> fs >> fd >> t >> cp >> p >> ok
    [v, dd, dm, dl, dp, dh, fs, fd, t, cp, p] >> bad


sdi_transform()
