"""
sdi_generate  —  Phase 1 synthetic data refresh DAG (WBS 2.1).

Runs generator/generate.py to simulate one new business month and drops the
files into LANDING_DIR, then triggers sdi_ingest for those files — so the whole
chain (ingest → transform → query + storage) runs automatically and the mart /
dashboards visibly update. New data is appended; history is never replaced.

Trigger it with params:
    period        month to simulate, 'YYYY-MM'  (refresh 1 = 2026-01, refresh 2 = 2026-02)
    price_change  change the retail price of N medicines (new dim_medicine SCD2 versions)
    bad_rows      add N deliberately invalid rows (proves validation rejects them)

    airflow dags trigger sdi_generate \
        --conf '{"period": "2026-01", "price_change": 3, "bad_rows": 5}'

schedule=None (run on demand, one refresh at a time). retries=2.
"""
import sys
from datetime import datetime, timedelta
from pathlib import Path

from airflow.providers.standard.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.sdk import Param, dag, get_current_context, task

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT / "generator") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "generator"))

import generate as GEN   # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))   # dags dir, for ida_dag_utils
from ida_dag_utils import pipeline_run_failure  # noqa: E402

DAG_ID = "sdi_generate"
default_args = {"owner": "ida", "retries": 2, "retry_delay": timedelta(minutes=1),
                "on_failure_callback": pipeline_run_failure,
                "execution_timeout": timedelta(minutes=30)}   # guards the 200MB resample


@dag(
    dag_id=DAG_ID,
    start_date=datetime(2026, 11, 1),
    schedule=None,
    catchup=False,
    default_args=default_args,
    params={
        "period": Param("2026-01", type="string",
                        description="Month to simulate, YYYY-MM"),
        "price_change": Param(0, type="integer", minimum=0,
                              description="Change retail price of N medicines (SCD2)"),
        "bad_rows": Param(0, type="integer", minimum=0,
                          description="Add N deliberately invalid rows"),
    },
    tags=["phase1", "sdi", "generator", "oversampling"],
)
def sdi_generate():

    @task
    def generate_period() -> list[str]:
        """Generate one month of data into LANDING_DIR; return the file names."""
        p = get_current_context()["params"]
        run_id = "gen_" + datetime.now().strftime("%Y%m%dT%H%M%S")
        results = GEN.generate(period=p["period"], price_change=int(p["price_change"]),
                               bad_rows=int(p["bad_rows"]), run_id=run_id)
        files = [r["source_file"] for r in results]
        print(f"generate_period: wrote {files}")
        return files

    # Hand off to the existing chain: sdi_ingest scans LANDING_DIR (where the
    # files were just dropped), which cascades ingest -> transform -> query/storage.
    trigger_ingest = TriggerDagRunOperator(
        task_id="trigger_ingest",
        trigger_dag_id="sdi_ingest",
        conf={"refresh_label": "gen_{{ params.period }}"},
        wait_for_completion=False,
        reset_dag_run=True,
    )

    generate_period() >> trigger_ingest


sdi_generate()
