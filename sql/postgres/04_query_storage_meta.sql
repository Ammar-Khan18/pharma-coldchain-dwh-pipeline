-- =====================================================================
-- 04_query_storage_meta.sql  —  small, additive meta changes for the query
-- layer and storage metrics. Run as ida_user. Safe to re-run.
--
-- These are the only schema changes the query/storage layers need; the existing
-- meta.query_log and meta.storage_snapshot columns are otherwise matched exactly.
--
--   meta.query_log.query_name          which .sql file ran (widget is the label)
--   meta.storage_snapshot.distinct_year_months  date-coverage breadth for facts/ODS
--   meta.storage_snapshot.layer CHECK  widened to also allow 'meta' (so the meta
--                                      schema's own tables can be measured)
--
-- Ubuntu (WSL):
--   PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -f ~/pipeline/sql/postgres/04_query_storage_meta.sql
-- =====================================================================

ALTER TABLE meta.query_log       ADD COLUMN IF NOT EXISTS query_name TEXT;
ALTER TABLE meta.storage_snapshot ADD COLUMN IF NOT EXISTS distinct_year_months INTEGER;

-- Allow layer = 'meta' as well (the original CHECK only permits ods/mart/duckdb).
ALTER TABLE meta.storage_snapshot DROP CONSTRAINT IF EXISTS storage_snapshot_layer_check;
ALTER TABLE meta.storage_snapshot DROP CONSTRAINT IF EXISTS storage_snapshot_layer_chk;
ALTER TABLE meta.storage_snapshot
    ADD CONSTRAINT storage_snapshot_layer_chk
    CHECK (layer IN ('ods', 'meta', 'mart', 'duckdb'));
