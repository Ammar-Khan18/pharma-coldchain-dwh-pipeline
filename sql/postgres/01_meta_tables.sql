-- =====================================================================
-- Pipeline observability tables (Postgres schema meta) — read by Grafana
-- File: sql/postgres/01_meta_tables.sql      Run as ida_user. Safe to re-run.
--
-- Ubuntu (WSL):
--   PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -f ~/pipeline/sql/postgres/01_meta_tables.sql
--
-- Dashboard -> table
--   Batch ingestion      -> meta.batch_log
--   Streaming ingestion  -> meta.stream_log
--   Storage              -> meta.storage_snapshot
--   Query layer          -> meta.query_log
--   Data quality         -> meta.dq_log
--   Refresh 1 vs 2       -> meta.pipeline_run  (one row per pipeline run)
-- =====================================================================

CREATE TABLE IF NOT EXISTS meta.pipeline_run (
    etl_batch_id    TEXT PRIMARY KEY,           -- e.g. 'sdi_20261110T2130'
    dag_id          TEXT,
    run_id          TEXT,                       -- Airflow run_id
    phase           TEXT,                       -- 'P1_SDI', 'P2_INV', ...
    refresh_label   TEXT,                       -- 'initial', 'refresh_1', 'refresh_2'
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at     TIMESTAMPTZ,
    status          TEXT NOT NULL DEFAULT 'RUNNING'
                    CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    notes           TEXT
);

CREATE TABLE IF NOT EXISTS meta.batch_log (
    batch_log_id    BIGSERIAL PRIMARY KEY,
    etl_batch_id    TEXT,
    dag_id          TEXT,
    task_id         TEXT,
    source_file     TEXT NOT NULL,              -- '05_pharmacy_sales_data.csv'
    target_table    TEXT,                       -- 'ods.pharmacy_sales'
    file_size_mb    NUMERIC(12,2),
    started_at      TIMESTAMPTZ NOT NULL,
    finished_at     TIMESTAMPTZ,
    duration_sec    NUMERIC(12,3),              -- finished_at - started_at
    rows_read       BIGINT,                     -- len(df)
    rows_loaded     BIGINT,
    rows_rejected   BIGINT DEFAULT 0,
    status          TEXT NOT NULL CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    error_message   TEXT
);
CREATE INDEX IF NOT EXISTS ix_batch_log_started ON meta.batch_log (started_at);

CREATE TABLE IF NOT EXISTS meta.stream_log (
    stream_log_id    BIGSERIAL PRIMARY KEY,
    etl_batch_id     TEXT,
    stream_name      TEXT NOT NULL,             -- 'iot_sensor'
    window_start     TIMESTAMPTZ NOT NULL,
    window_end       TIMESTAMPTZ NOT NULL,
    events_received  BIGINT,
    events_inserted  BIGINT,
    events_dropped   BIGINT,                    -- malformed / null keys
    throughput_eps   NUMERIC(12,2),             -- events_inserted / window seconds
    avg_latency_sec  NUMERIC(12,3),             -- db_insert_ts - source_ts
    p95_latency_sec  NUMERIC(12,3),
    max_latency_sec  NUMERIC(12,3),
    logged_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_stream_log_window ON meta.stream_log (window_end);

CREATE TABLE IF NOT EXISTS meta.storage_snapshot (
    storage_snapshot_id BIGSERIAL PRIMARY KEY,
    snapshot_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    etl_batch_id    TEXT,
    layer           TEXT NOT NULL CHECK (layer IN ('ods', 'mart', 'duckdb')),
    source_domain   TEXT,                       -- 'master', 'sales', 'hospital_demand', ...
    table_name      TEXT NOT NULL,
    row_count       BIGINT,
    size_mb         NUMERIC(12,2),
    min_date        DATE,                       -- date coverage span
    max_date        DATE
);
CREATE INDEX IF NOT EXISTS ix_storage_snapshot_at ON meta.storage_snapshot (snapshot_at);

CREATE TABLE IF NOT EXISTS meta.query_log (
    query_log_id    BIGSERIAL PRIMARY KEY,
    executed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    etl_batch_id    TEXT,
    engine          TEXT NOT NULL DEFAULT 'duckdb',
    dashboard       TEXT,                       -- 'SDI'
    widget          TEXT NOT NULL,              -- 'Channel revenue split'
    optimized       BOOLEAN,                    -- base tables vs pre-aggregate, for before/after
    duration_ms     NUMERIC(12,3),
    rows_returned   BIGINT,
    status          TEXT NOT NULL CHECK (status IN ('SUCCESS', 'FAILED')),
    error_message   TEXT
);
CREATE INDEX IF NOT EXISTS ix_query_log_executed ON meta.query_log (executed_at);

CREATE TABLE IF NOT EXISTS meta.dq_log (
    dq_log_id       BIGSERIAL PRIMARY KEY,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    etl_batch_id    TEXT,
    source_file     TEXT,
    rule_id         TEXT NOT NULL,              -- 'S6'
    rule_action     TEXT NOT NULL CHECK (rule_action IN ('REJECT', 'WARN')),
    rows_checked    BIGINT,
    rows_failed     BIGINT
);
CREATE INDEX IF NOT EXISTS ix_dq_log_logged ON meta.dq_log (logged_at);
