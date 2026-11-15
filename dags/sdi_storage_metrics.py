"""
sdi_storage_metrics  —  Phase 1 storage metrics DAG (WBS 2.4.3).

Runs ingestion/storage_metrics.py to append per-table row counts, sizes, and
date coverage for the Postgres schemas (ods, meta, mart) and the DuckDB sdi
schema to meta.storage_snapshot. The "storage" dashboard reads this to show how
each layer grows and how storage is shared across the source domains.

Schedule: hourly AND after every successful sdi_transform (the mart Asset), via
AssetOrTimeSchedule — so there is a regular heartbeat plus a fresh snapshot right
after each refresh. retries=2.
"""
import sys
from datetime import datetime, timedelta
from pathlib import Path

from airflow.sdk import Asset, Connection, Variable, dag, task
from airflow.timetables.assets import AssetOrTimeSchedule
from airflow.timetables.trigger import CronTriggerTimetable

REPO_ROOT = Path(__file__).resolve().parents[1]
p = str(REPO_ROOT / "ingestion")
if p not in sys.path:
    sys.path.insert(0, p)

import storage_metrics as SM   # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))   # dags dir, for ida_dag_utils
from ida_dag_utils import pipeline_run_failure  # noqa: E402

DAG_ID = "sdi_storage_metrics"
SDI_MART_ASSET = Asset(name="sdi_mart_published", uri="sdi://mart/phase1")

default_args = {"owner": "ida", "retries": 2, "retry_delay": timedelta(minutes=1),
                "on_failure_callback": pipeline_run_failure,
                "execution_timeout": timedelta(minutes=15)}   # guards the storage census


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
    schedule=AssetOrTimeSchedule(
        timetable=CronTriggerTimetable("0 * * * *", timezone="UTC"),   # hourly
        assets=[SDI_MART_ASSET],                                       # and after transform
    ),
    catchup=False,
    default_args=default_args,
    tags=["phase1", "sdi", "storage", "metrics"],
)
def sdi_storage_metrics():

    @task
    def take_snapshot() -> int:
        batch_id = "sstor_" + datetime.now().strftime("%Y%m%dT%H%M%S")
        n = SM.snapshot(dsn=_pg_dsn(), duck_path=_duck_path(), batch_id=batch_id)
        print(f"take_snapshot: {n} rows (batch {batch_id})")
        return n

    take_snapshot()


sdi_storage_metrics()
