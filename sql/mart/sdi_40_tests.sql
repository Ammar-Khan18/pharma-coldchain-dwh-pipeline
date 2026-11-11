-- =====================================================================
-- sdi_40_tests.sql  —  Phase 1 transform, STEP 4: data tests (DuckDB)
-- WBS 3.2. Builds stg._test_results (test_name, passed, detail). The Python
-- data_tests task reads it and FAILS the Airflow task if any test did not pass,
-- so a broken load never reaches publish / Power BI.
--
-- Tests:
--   * unique natural keys in each fact
--   * no NULL surrogate keys in the facts
--   * every fact foreign key exists in its dimension (the -1 member counts)
--   * row counts reconcile for THIS batch:
--       ODS rows processed = fact rows loaded this batch + rejected rows this batch
-- =====================================================================

CREATE OR REPLACE TABLE stg._test_results AS
SELECT * FROM (
    -- unique natural keys ------------------------------------------------
    SELECT 'fact_sales_unique_pk' AS test_name,
           (count(*) = count(DISTINCT sales_transaction_id)) AS passed,
           'rows=' || count(*) || ' distinct=' || count(DISTINCT sales_transaction_id) AS detail
    FROM sdi.fact_sales
    UNION ALL
    SELECT 'fact_demand_unique_pk',
           (count(*) = count(DISTINCT hospital_demand_record_id)),
           'rows=' || count(*) || ' distinct=' || count(DISTINCT hospital_demand_record_id)
    FROM sdi.fact_hospital_demand

    -- no NULL surrogate keys --------------------------------------------
    UNION ALL
    SELECT 'fact_sales_no_null_keys', (count(*) = 0), 'null_key_rows=' || count(*)
    FROM sdi.fact_sales
    WHERE sale_date_key IS NULL OR pharmacy_delivery_date_key IS NULL
       OR batch_expiry_date_key IS NULL OR medicine_key IS NULL OR pharmacy_key IS NULL
       OR hospital_key IS NULL OR channel_key IS NULL OR sales_profile_key IS NULL
    UNION ALL
    SELECT 'fact_demand_no_null_keys', (count(*) = 0), 'null_key_rows=' || count(*)
    FROM sdi.fact_hospital_demand
    WHERE month_date_key IS NULL OR hospital_key IS NULL OR medicine_key IS NULL
       OR demand_status_key IS NULL

    -- referential integrity (every FK is a real dim key, -1 included) ----
    UNION ALL
    SELECT 'fact_sales_fk_in_dims', (count(*) = 0), 'orphan_fk_rows=' || count(*)
    FROM sdi.fact_sales f
    WHERE f.medicine_key      NOT IN (SELECT medicine_key FROM sdi.dim_medicine)
       OR f.pharmacy_key      NOT IN (SELECT pharmacy_key FROM sdi.dim_pharmacy)
       OR f.hospital_key      NOT IN (SELECT hospital_key FROM sdi.dim_hospital)
       OR f.channel_key       NOT IN (SELECT channel_key FROM sdi.dim_channel)
       OR f.sales_profile_key NOT IN (SELECT sales_profile_key FROM sdi.dim_sales_profile)
       OR f.sale_date_key     NOT IN (SELECT date_key FROM sdi.dim_date)
    UNION ALL
    SELECT 'fact_demand_fk_in_dims', (count(*) = 0), 'orphan_fk_rows=' || count(*)
    FROM sdi.fact_hospital_demand f
    WHERE f.medicine_key      NOT IN (SELECT medicine_key FROM sdi.dim_medicine)
       OR f.hospital_key      NOT IN (SELECT hospital_key FROM sdi.dim_hospital)
       OR f.demand_status_key NOT IN (SELECT demand_status_key FROM sdi.dim_demand_status)
       OR f.month_date_key    NOT IN (SELECT date_key FROM sdi.dim_date)

    -- reconciliation for THIS batch -------------------------------------
    UNION ALL
    SELECT 'reconcile_sales',
           ( (SELECT attempted_new FROM stg._recon WHERE source_table = 'ods.pharmacy_sales')
             = (SELECT count(*) FROM sdi.fact_sales WHERE etl_batch_id = (SELECT etl_batch_id FROM stg._batch))
             + (SELECT count(*) FROM stg._rejected WHERE source_table = 'ods.pharmacy_sales') ),
           'attempted=' || (SELECT attempted_new FROM stg._recon WHERE source_table = 'ods.pharmacy_sales')
           || ' loaded=' || (SELECT count(*) FROM sdi.fact_sales WHERE etl_batch_id = (SELECT etl_batch_id FROM stg._batch))
           || ' rejected=' || (SELECT count(*) FROM stg._rejected WHERE source_table = 'ods.pharmacy_sales')
    UNION ALL
    SELECT 'reconcile_demand',
           ( (SELECT attempted_new FROM stg._recon WHERE source_table = 'ods.hospital_demand')
             = (SELECT count(*) FROM sdi.fact_hospital_demand WHERE etl_batch_id = (SELECT etl_batch_id FROM stg._batch))
             + (SELECT count(*) FROM stg._rejected WHERE source_table = 'ods.hospital_demand') ),
           'attempted=' || (SELECT attempted_new FROM stg._recon WHERE source_table = 'ods.hospital_demand')
           || ' loaded=' || (SELECT count(*) FROM sdi.fact_hospital_demand WHERE etl_batch_id = (SELECT etl_batch_id FROM stg._batch))
           || ' rejected=' || (SELECT count(*) FROM stg._rejected WHERE source_table = 'ods.hospital_demand')
) ORDER BY test_name;
