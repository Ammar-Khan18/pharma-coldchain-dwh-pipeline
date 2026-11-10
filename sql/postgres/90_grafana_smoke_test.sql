-- =====================================================================
-- Grafana smoke test (WBS 1.3.6): fake rows so you can build a first panel
-- before the real ingestion DAG exists.   Run as ida_user:
--   PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -f ~/pipeline/sql/postgres/90_grafana_smoke_test.sql
-- Remove afterwards:
--   PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -c "DELETE FROM meta.batch_log WHERE etl_batch_id = 'SMOKE_TEST'"
-- =====================================================================
INSERT INTO meta.batch_log (etl_batch_id, dag_id, task_id, source_file, target_table,
                            file_size_mb, started_at, finished_at, duration_sec,
                            rows_read, rows_loaded, status)
VALUES
 ('SMOKE_TEST','smoke','load_01','01_master_data.csv','ods.master_data',            0.02, now()-interval '3 min', now()-interval '3 min'+interval '0.4 s',  0.4,     63,     63,'SUCCESS'),
 ('SMOKE_TEST','smoke','load_05','05_pharmacy_sales_data.csv','ods.pharmacy_sales',208.5, now()-interval '2 min', now()-interval '2 min'+interval '41 s',  41.0, 500000, 500000,'SUCCESS'),
 ('SMOKE_TEST','smoke','load_06','06_hospital_demand_data.csv','ods.hospital_demand',8.3, now()-interval '1 min', now()-interval '1 min'+interval '2.6 s',  2.6,  27216,  27216,'SUCCESS');
