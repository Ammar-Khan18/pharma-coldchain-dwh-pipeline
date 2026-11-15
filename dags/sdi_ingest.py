"""
sdi_ingest  —  Phase 1 batch ingestion DAG (raw CSV -> Postgres ODS).

WBS 2.x. Orchestrates the ingestion layer built in ingestion/ingest_api.py.

Flow (modular, one responsibility per task):

    start_run  ->  list_files  ->  ingest[ file_1 ]  ->  finish_run
                                   ingest[ file_2 ]
                                   ingest[ file_N ]   (dynamic task mapping)

    start_run    open a meta.pipeline_run row (status RUNNING) and mint the
                 etl_batch_id that every row loaded in this run will carry.
    list_files   decide which files to load: the ones named in the run `conf`
                 (passed by the file-watcher), or, if none, every *.csv in
                 LANDING_DIR.
    ingest       one mapped task per file; each calls ingest_api.ingest_file,
                 which COPYs it into its ODS table, logs meta.batch_log, and
                 archives it. Retries twice on failure (default_args).
    finish_run   close the meta.pipeline_run row (SUCCESS / FAILED) from what
                 actually landed in meta.batch_log. Runs even if a file failed.

Trigger it by hand:
    airflow dags trigger sdi_ingest
    airflow dags trigger sdi_ingest --conf '{"files": ["05_pharmacy_sales_data.csv"]}'
The file-watcher (ingestion/file_watcher.py) triggers it automatically.

Config / Variables: LANDING_DIR, ARCHIVE_DIR (Airflow Variables); the Postgres
connection `ida_postgres`. Nothing here touches the mart.
"""
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg2
from airflow.sdk import Asset, Connection, Variable, dag, get_current_context, task

# When this ingest run fully succeeds, it "produces" this Asset, which is what
# sdi_transform is scheduled on — so a good ingest auto-triggers the transform.
SDI_ODS_ASSET = Asset(name="sdi_ods_loaded", uri="sdi://ods/phase1")

# Make ingestion/ingest_api.py importable (dags/ and ingestion/ are siblings).
REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT / "ingestion") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "ingestion"))

from ingest_api import ingest_file  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))   # dags dir, for ida_dag_utils
from ida_dag_utils import pipeline_run_failure  # noqa: E402

DAG_ID = "sdi_ingest"
PHASE = "P1_SDI"


# ---------------------------------------------------------------------------
# small runtime helpers (resolved inside tasks, where connections/vars exist)
# ---------------------------------------------------------------------------
def _pg_dsn() -> str:
    """psycopg2 DSN built from the Airflow connection `ida_postgres`."""
    c = Connection.get("ida_postgres")
    return (f"host={c.host} port={c.port or 5432} dbname={c.schema} "
            f"user={c.login} password={c.password}")


def _var(key: str, fallback: str) -> str:
    """Read an Airflow Variable, falling back to a sensible default path."""
    try:
        val = Variable.get(key)
        return val if val else fallback
    except Exception:
        return fallback


def _landing_dir() -> Path:
    return Path(_var("LANDING_DIR", str(Path.home() / "pipeline" / "landing")))


default_args = {
    "owner": "ida",
    "retries": 2,
    "retry_delay": timedelta(minutes=1),
    "on_failure_callback": pipeline_run_failure,
    "execution_timeout": timedelta(minutes=30),   # guards the long COPY of large files
}


@dag(
    dag_id=DAG_ID,
    start_date=datetime(2026, 11, 1),
    schedule=None,              # triggered by the file-watcher or by hand
    catchup=False,
    default_args=default_args,
    tags=["phase1", "sdi", "ingestion", "ods"],
)
def sdi_ingest():

    @task
    def start_run() -> str:
        """Mint the etl_batch_id and open the meta.pipeline_run row."""
        ctx = get_current_context()
        dag_run = ctx["dag_run"]
        conf = dag_run.conf or {}
        etl_batch_id = "sdi_" + datetime.now().strftime("%Y%m%dT%H%M%S")
        refresh_label = conf.get("refresh_label", "initial")

        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO meta.pipeline_run "
                "(etl_batch_id, dag_id, run_id, phase, refresh_label, started_at, status) "
                "VALUES (%s, %s, %s, %s, %s, %s, 'RUNNING')",
                (etl_batch_id, DAG_ID, dag_run.run_id, PHASE, refresh_label,
                 datetime.now(timezone.utc)),
            )
        print(f"start_run: etl_batch_id={etl_batch_id} refresh={refresh_label}")
        return etl_batch_id

    @task
    def list_files() -> list[str]:
        """Which files to load: those named in the run conf, else every *.csv in
        LANDING_DIR. Returns absolute paths."""
        ctx = get_current_context()
        conf = (ctx["dag_run"].conf or {})
        landing = _landing_dir()

        names = conf.get("files")
        if not names and conf.get("file"):
            names = [conf["file"]]

        if names:
            paths = []
            for n in names:
                p = Path(n)
                paths.append(str(p if p.is_absolute() else landing / p.name))
        else:
            paths = [str(p) for p in sorted(landing.glob("*.csv"))]

        print(f"list_files: {len(paths)} file(s) to ingest from {landing}: "
              f"{[Path(p).name for p in paths]}")
        return paths

    @task
    def ingest(path: str, etl_batch_id: str) -> dict:
        """Load one file into its ODS table (one mapped task per file)."""
        ctx = get_current_context()
        result = ingest_file(
            path,
            etl_batch_id=etl_batch_id,
            dsn=_pg_dsn(),
            archive_dir=_var("ARCHIVE_DIR", str(Path.home() / "pipeline" / "archive")),
            dag_id=DAG_ID,
            task_id=ctx["ti"].task_id,
        )
        print(f"ingest: {result}")
        return result

    @task(trigger_rule="all_done")
    def finish_run(etl_batch_id: str) -> dict:
        """Close the pipeline_run row from what actually reached meta.batch_log,
        so it is correct even if a file failed (trigger_rule=all_done)."""
        with psycopg2.connect(_pg_dsn()) as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT status, COALESCE(SUM(rows_loaded), 0) "
                "FROM meta.batch_log WHERE etl_batch_id = %s GROUP BY status",
                (etl_batch_id,),
            )
            by_status = {r[0]: int(r[1]) for r in cur.fetchall()}
            total_rows = sum(by_status.values())
            status = "FAILED" if "FAILED" in by_status else "SUCCESS"
            notes = ("loaded " + ", ".join(f"{k}={v}" for k, v in sorted(by_status.items()))
                     + f"; total rows_loaded={total_rows}") if by_status else "no files"

            cur.execute(
                "UPDATE meta.pipeline_run "
                "SET finished_at = %s, status = %s, notes = %s "
                "WHERE etl_batch_id = %s",
                (datetime.now(timezone.utc), status, notes, etl_batch_id),
            )
        print(f"finish_run: {status} ({notes})")
        return {"etl_batch_id": etl_batch_id, "status": status, "notes": notes}

    @task(outlets=[SDI_ODS_ASSET])
    def signal_ods_ready(etl_batch_id: str) -> None:
        """Produce the ODS Asset so sdi_transform fires. Runs only if every ingest
        task succeeded (default all_success trigger rule)."""
        print(f"signal_ods_ready: ODS loaded for {etl_batch_id}; "
              f"updating Asset {SDI_ODS_ASSET.uri} -> sdi_transform will be triggered.")

    batch_id = start_run()
    files = list_files()
    loaded = ingest.partial(etl_batch_id=batch_id).expand(path=files)
    done = finish_run(batch_id)
    ready = signal_ods_ready(batch_id)

    # Order: files listed before mapping; finish waits for all ingests (all_done);
    # the Asset is produced only when every ingest succeeded.
    batch_id >> files
    loaded >> done
    loaded >> ready


sdi_ingest()
