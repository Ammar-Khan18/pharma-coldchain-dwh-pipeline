-- =====================================================================
-- 06_ods_indexes.sql  —  indexes on the ODS tables for the keys the transform
-- reads by. Run as ida_user. Safe to re-run (CREATE INDEX IF NOT EXISTS).
--
-- The transform (sql/mart/sdi_10_validate.sql) reads each ODS table by its
-- NATURAL KEY (to skip rows already loaded / to keep the latest row per key) and
-- orders the "latest per key" window by loaded_at. These indexes cover those
-- access paths and point lookups / incremental-by-key reads.
--
-- (The etl_batch_id indexes already exist — see sql/postgres/02_ods_tables.sql:
--  ix_ods_master_data_batch, ix_ods_pharmacy_sales_batch, ix_ods_hospital_demand_batch.)
--
-- Ubuntu (WSL):
--   PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -f ~/pipeline/sql/postgres/06_ods_indexes.sql
-- =====================================================================

-- natural keys (used by the transform's "new rows only" anti-join / dedup)
CREATE INDEX IF NOT EXISTS ix_ods_pharmacy_sales_txn
    ON ods.pharmacy_sales ("SalesTransactionID");
CREATE INDEX IF NOT EXISTS ix_ods_hospital_demand_rec
    ON ods.hospital_demand ("HospitalDemandRecordID");
CREATE INDEX IF NOT EXISTS ix_ods_master_data_medicine
    ON ods.master_data ("MedicineID");

-- loaded_at (the "latest version per natural key" window orders by it)
CREATE INDEX IF NOT EXISTS ix_ods_pharmacy_sales_loaded
    ON ods.pharmacy_sales (loaded_at);
CREATE INDEX IF NOT EXISTS ix_ods_hospital_demand_loaded
    ON ods.hospital_demand (loaded_at);
CREATE INDEX IF NOT EXISTS ix_ods_master_data_loaded
    ON ods.master_data (loaded_at);

-- refresh planner statistics so these indexes can be chosen
ANALYZE ods.pharmacy_sales;
ANALYZE ods.hospital_demand;
ANALYZE ods.master_data;
