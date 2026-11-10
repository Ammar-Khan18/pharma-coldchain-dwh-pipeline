-- =====================================================================
-- WBS 1.3.6  BI access setup  —  run ONCE as the postgres superuser
-- File: sql/postgres/00_bi_access.sql
--
-- Ubuntu (WSL):
--   sudo -u postgres psql -d ida_staging < ~/pipeline/sql/postgres/00_bi_access.sql
--
-- What it does
--   * mart schema  = "serving shelf": copies of the DuckDB mart tables that
--                    Power BI reads (refreshed by serving/publish_mart.py)
--   * meta schema  = pipeline logs that Grafana reads
--   * bi_reader    = a READ-ONLY login used by both Power BI and Grafana,
--                    so a dashboard can never change or delete data
-- Safe to run again.
-- =====================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bi_reader') THEN
        CREATE ROLE bi_reader LOGIN PASSWORD 'bi_pass';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE ida_staging TO bi_reader;

-- Schemas (no-op if they already exist)
CREATE SCHEMA IF NOT EXISTS ods  AUTHORIZATION ida_user;
CREATE SCHEMA IF NOT EXISTS meta AUTHORIZATION ida_user;
CREATE SCHEMA IF NOT EXISTS mart AUTHORIZATION ida_user;

-- The pipeline user can create and fill tables in all three
GRANT USAGE, CREATE ON SCHEMA ods, meta, mart TO ida_user;

-- The BI user can only look, and only at logs (meta) and the serving copy (mart).
-- Raw staging (ods) stays private; storage numbers reach Grafana via meta.storage_snapshot.
GRANT USAGE ON SCHEMA meta, mart TO bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA meta, mart TO bi_reader;

-- ...including tables ida_user creates in the future
ALTER DEFAULT PRIVILEGES FOR ROLE ida_user IN SCHEMA meta, mart
    GRANT SELECT ON TABLES TO bi_reader;
