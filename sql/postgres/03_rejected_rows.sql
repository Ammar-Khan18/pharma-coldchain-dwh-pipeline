-- =====================================================================
-- ods.rejected_rows  —  the "quarantine" for rows that fail a REJECT rule
-- File: sql/postgres/03_rejected_rows.sql     Run as ida_user. Safe to re-run.
--
-- The transform step (sql/mart/sdi_10_validate.sql) applies the Phase 1 REJECT
-- rules (M1–M6, S1–S7, H1–H9 in docs/phase1_sdi_design.md). A row that breaks a
-- REJECT rule never enters the mart; instead it is written here with the rule it
-- broke, a plain-language reason, and the full raw row as JSON, so nothing is
-- lost and every rejection is auditable. WARN rows are NOT stored here — they
-- load into the fact with dq_warning_count raised and are counted in meta.dq_log.
--
-- Ubuntu (WSL):
--   PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -f ~/pipeline/sql/postgres/03_rejected_rows.sql
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS ods;

CREATE TABLE IF NOT EXISTS ods.rejected_rows (
    rejected_row_id BIGSERIAL PRIMARY KEY,
    source_table    TEXT NOT NULL,              -- 'ods.pharmacy_sales'
    natural_key     TEXT,                       -- e.g. SalesTransactionID value
    rule_id         TEXT NOT NULL,              -- 'S6'
    reason          TEXT,                       -- 'UnitRetailPriceUSD must be > 0'
    raw_row         JSONB,                      -- the full source row, as received
    etl_batch_id    TEXT,                       -- the transform run that rejected it
    rejected_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_rejected_rows_batch ON ods.rejected_rows (etl_batch_id);
CREATE INDEX IF NOT EXISTS ix_rejected_rows_rule  ON ods.rejected_rows (rule_id);
