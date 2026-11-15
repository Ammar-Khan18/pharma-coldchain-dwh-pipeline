"""
ida_dag_utils.py  —  shared failure handling for the sdi_* DAGs.

Observability only: this adds an on_failure_callback that records a FAILED row in
meta.pipeline_run and logs a clear message whenever a task finally fails (after
its retries are exhausted). It changes no business logic — the DAGs' own
start_run / finish tasks still behave exactly as before; this is a safety net so
a failure is always visible in the pipeline_run table and the task log.
"""


def pipeline_run_failure(context) -> None:
    """on_failure_callback for every sdi_* task. Writes/updates one FAILED
    meta.pipeline_run row for the failed DAG run and logs the error."""
    ti = context.get("task_instance") or context.get("ti")
    dag_run = context.get("dag_run")
    exc = context.get("exception")
    dag_id = getattr(dag_run, "dag_id", None) or getattr(ti, "dag_id", "unknown")
    run_id = getattr(dag_run, "run_id", None) or getattr(ti, "run_id", "unknown")
    task_id = getattr(ti, "task_id", "unknown")
    etl_batch_id = f"fail_{dag_id}_{run_id}"[:250]
    notes = f"task '{task_id}' failed: {exc}"[:1000]
    print(f"[on_failure_callback] {dag_id} run={run_id}: {notes}")
    try:
        import psycopg2
        from airflow.sdk import Connection
        c = Connection.get("ida_postgres")
        dsn = (f"host={c.host} port={c.port or 5432} dbname={c.schema} "
               f"user={c.login} password={c.password}")
        with psycopg2.connect(dsn) as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO meta.pipeline_run "
                "(etl_batch_id, dag_id, run_id, phase, refresh_label, started_at, "
                " finished_at, status, notes) "
                "VALUES (%s, %s, %s, 'P1_SDI', 'failure', now(), now(), 'FAILED', %s) "
                "ON CONFLICT (etl_batch_id) DO UPDATE SET "
                "finished_at = now(), status = 'FAILED', notes = EXCLUDED.notes",
                (etl_batch_id, dag_id, run_id, notes),
            )
        print(f"[on_failure_callback] wrote FAILED pipeline_run row '{etl_batch_id}'")
    except Exception as e:                       # never let the callback itself raise
        print(f"[on_failure_callback] could not write pipeline_run: {e}")
