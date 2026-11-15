-- =====================================================================
-- 05_generation_log.sql  —  log of synthetic data refreshes (WBS 2.1)
-- File: sql/postgres/05_generation_log.sql     Run as ida_user. Safe to re-run.
--
-- generator/generate.py writes one row here per generated file, so the project
-- report (and a Grafana panel) can show exactly what each refresh produced:
-- the period simulated, the file, how many rows (and how many deliberately bad
-- rows) it contains, and the date span. Read-only access is granted to bi_reader.
--
-- Ubuntu (WSL):
--   PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -f ~/pipeline/sql/postgres/05_generation_log.sql
-- =====================================================================

CREATE TABLE IF NOT EXISTS meta.generation_log (
    generation_log_id BIGSERIAL PRIMARY KEY,
    run_id          TEXT,                       -- 'gen_20260115T...' (one per generator run)
    period          TEXT,                       -- the simulated month, 'YYYY-MM'
    source_file     TEXT NOT NULL,              -- generated file name dropped into landing
    rows_generated  BIGINT,                     -- good rows written
    bad_rows        BIGINT DEFAULT 0,           -- deliberately invalid rows added
    min_date        DATE,                       -- date span of the generated rows
    max_date        DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_generation_log_created ON meta.generation_log (created_at);

GRANT SELECT ON meta.generation_log TO bi_reader;
