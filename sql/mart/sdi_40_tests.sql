-- =====================================================================
-- sdi_40_tests.sql  —  Phase 1 transform STEP 4: data tests (DuckDB)
-- Builds stg._test_results (test_name, passed, detail). The Python data_tests
-- task fails the Airflow task (and the run) if any test did not pass.
--
-- Tests (Excel model):
--   * reconciliation: attempted = clean + rejected (per source), and every clean
--     row reached its fact.
--   * SalesTransactionID unique in FactPharmacySales.
--   * no fact row matched to more than one DimMedicine version (point-in-time).
--   * exactly one IsCurrent='Y' per InternalSKU; no overlapping effective ranges.
--   * every fact DateKey exists in DimDate.
--   * SUM(NetSales) = SUM(GrossSales) - SUM(Discount).
--   * each fact row's DimPharmacy.SalesChannel matches the sale's channel (R1).
--   * % of -1 keys per FK is logged and must be < 1%.
-- =====================================================================
CREATE OR REPLACE TABLE stg._test_results AS
SELECT * FROM (
    -- reconciliation: counts add up -------------------------------------
    SELECT 'reconcile_sales_counts' AS test_name,
           (attempted_new = clean_cnt + rejected_cnt) AS passed,
           'attempted=' || attempted_new || ' clean=' || clean_cnt || ' rejected=' || rejected_cnt AS detail
    FROM stg._recon WHERE source_table = 'ods.pharmacy_sales'
    UNION ALL
    SELECT 'reconcile_demand_counts',
           (attempted_new = clean_cnt + rejected_cnt),
           'attempted=' || attempted_new || ' clean=' || clean_cnt || ' rejected=' || rejected_cnt
    FROM stg._recon WHERE source_table = 'ods.hospital_demand'

    -- every clean row reached its fact ----------------------------------
    UNION ALL
    SELECT 'sales_rows_loaded',
           ((SELECT count(*) FROM stg._clean_sales)
            = (SELECT count(*) FROM sdi."FactPharmacySales" f
               WHERE f."SalesTransactionID" IN (SELECT sales_transaction_id FROM stg._clean_sales))),
           'clean=' || (SELECT count(*) FROM stg._clean_sales)
           || ' in_fact=' || (SELECT count(*) FROM sdi."FactPharmacySales" f
               WHERE f."SalesTransactionID" IN (SELECT sales_transaction_id FROM stg._clean_sales))
    UNION ALL
    SELECT 'demand_rows_loaded',
           ((SELECT count(*) FROM stg._clean_demand)
            = (SELECT count(*) FROM stg._clean_demand c
               WHERE EXISTS (SELECT 1 FROM sdi."FactHospitalDemand" f
                             JOIN sdi."DimHospital" h ON h."HospitalKey" = f."HospitalKey"
                             WHERE f."DateKey" = CAST(strftime(c.demand_month, '%Y%m%d') AS INTEGER)
                               AND h."HospitalID" = c.hospital_id
                               AND f."MedicineKey" IN (SELECT "MedicineKey" FROM sdi."DimMedicine" WHERE "GTIN14" = c.gtin14)))),
           'clean=' || (SELECT count(*) FROM stg._clean_demand)

    -- unique sales PK ---------------------------------------------------
    UNION ALL
    SELECT 'fact_sales_unique_pk',
           (count(*) = count(DISTINCT "SalesTransactionID")),
           'rows=' || count(*) || ' distinct=' || count(DISTINCT "SalesTransactionID")
    FROM sdi."FactPharmacySales"

    -- no fact row matched to more than one DimMedicine version ----------
    UNION ALL
    SELECT 'sales_single_medicine_version',
           ((SELECT count(*) FROM (
               SELECT c.sales_transaction_id
               FROM stg._clean_sales c
               JOIN sdi."DimMedicine" m ON m."MedicineID" = c.medicine_id
                    AND c.sales_date BETWEEN m."EffectiveFrom" AND m."EffectiveTo" AND m."MedicineKey" <> -1
               GROUP BY c.sales_transaction_id HAVING count(*) > 1)) = 0),
           'multi_match_txns=' || (SELECT count(*) FROM (
               SELECT c.sales_transaction_id
               FROM stg._clean_sales c
               JOIN sdi."DimMedicine" m ON m."MedicineID" = c.medicine_id
                    AND c.sales_date BETWEEN m."EffectiveFrom" AND m."EffectiveTo" AND m."MedicineKey" <> -1
               GROUP BY c.sales_transaction_id HAVING count(*) > 1))
    UNION ALL
    SELECT 'demand_single_medicine_version',
           ((SELECT count(*) FROM (
               SELECT c.hospital_demand_record_id
               FROM stg._clean_demand c
               JOIN sdi."DimMedicine" m ON m."GTIN14" = c.gtin14
                    AND c.demand_month BETWEEN m."EffectiveFrom" AND m."EffectiveTo" AND m."MedicineKey" <> -1
               GROUP BY c.hospital_demand_record_id HAVING count(*) > 1)) = 0),
           'multi_match_records=' || (SELECT count(*) FROM (
               SELECT c.hospital_demand_record_id
               FROM stg._clean_demand c
               JOIN sdi."DimMedicine" m ON m."GTIN14" = c.gtin14
                    AND c.demand_month BETWEEN m."EffectiveFrom" AND m."EffectiveTo" AND m."MedicineKey" <> -1
               GROUP BY c.hospital_demand_record_id HAVING count(*) > 1))

    -- exactly one current version per InternalSKU -----------------------
    UNION ALL
    SELECT 'one_current_per_sku',
           ((SELECT count(*) FROM (
               SELECT "InternalSKU" FROM sdi."DimMedicine" WHERE "MedicineKey" <> -1 AND "IsCurrent" = 'Y'
               GROUP BY "InternalSKU" HAVING count(*) <> 1)) = 0),
           'skus_not_exactly_one_current=' || (SELECT count(*) FROM (
               SELECT "InternalSKU" FROM sdi."DimMedicine" WHERE "MedicineKey" <> -1 AND "IsCurrent" = 'Y'
               GROUP BY "InternalSKU" HAVING count(*) <> 1))

    -- no overlapping effective ranges per InternalSKU -------------------
    UNION ALL
    SELECT 'no_overlapping_scd2_ranges',
           ((SELECT count(*) FROM sdi."DimMedicine" a JOIN sdi."DimMedicine" b
               ON a."InternalSKU" = b."InternalSKU" AND a."MedicineKey" < b."MedicineKey"
              AND a."MedicineKey" <> -1 AND b."MedicineKey" <> -1
             WHERE a."EffectiveFrom" <= b."EffectiveTo" AND b."EffectiveFrom" <= a."EffectiveTo") = 0),
           'overlapping_pairs=' || (SELECT count(*) FROM sdi."DimMedicine" a JOIN sdi."DimMedicine" b
               ON a."InternalSKU" = b."InternalSKU" AND a."MedicineKey" < b."MedicineKey"
              AND a."MedicineKey" <> -1 AND b."MedicineKey" <> -1
             WHERE a."EffectiveFrom" <= b."EffectiveTo" AND b."EffectiveFrom" <= a."EffectiveTo")

    -- every fact DateKey exists in DimDate ------------------------------
    UNION ALL
    SELECT 'sales_datekey_in_dimdate', (count(*) = 0), 'missing=' || count(*)
    FROM sdi."FactPharmacySales" f
    WHERE f."DateKey" NOT IN (SELECT "DateKey" FROM sdi."DimDate")
    UNION ALL
    SELECT 'demand_datekey_in_dimdate', (count(*) = 0), 'missing=' || count(*)
    FROM sdi."FactHospitalDemand" f
    WHERE f."DateKey" NOT IN (SELECT "DateKey" FROM sdi."DimDate")

    -- additive money identity -------------------------------------------
    UNION ALL
    SELECT 'netsales_identity',
           (abs(coalesce(sum("NetSales"), 0) - (coalesce(sum("GrossSales"), 0) - coalesce(sum("Discount"), 0))) < 0.01),
           'net=' || coalesce(sum("NetSales"), 0) || ' gross-disc='
           || (coalesce(sum("GrossSales"), 0) - coalesce(sum("Discount"), 0))
    FROM sdi."FactPharmacySales"

    -- R1: fact's pharmacy channel matches the sale's channel ------------
    UNION ALL
    SELECT 'pharmacy_channel_matches_sale',
           ((SELECT count(*) FROM sdi."FactPharmacySales" f
             JOIN stg._clean_sales c ON c.sales_transaction_id = f."SalesTransactionID"
             JOIN sdi."DimPharmacy" p ON p."PharmacyKey" = f."PharmacyKey"
             WHERE f."PharmacyKey" <> -1 AND p."SalesChannel" <> c.sales_channel) = 0),
           'channel_mismatches=' || (SELECT count(*) FROM sdi."FactPharmacySales" f
             JOIN stg._clean_sales c ON c.sales_transaction_id = f."SalesTransactionID"
             JOIN sdi."DimPharmacy" p ON p."PharmacyKey" = f."PharmacyKey"
             WHERE f."PharmacyKey" <> -1 AND p."SalesChannel" <> c.sales_channel)

    -- % of -1 keys per FK, must be < 1% ---------------------------------
    UNION ALL
    SELECT 'pct_minus1_sales_medicine', (p < 1.0), 'pct=' || round(p, 4) FROM (
        SELECT 100.0 * count(*) FILTER (WHERE "MedicineKey" = -1) / nullif(count(*), 0) AS p
        FROM sdi."FactPharmacySales")
    UNION ALL
    SELECT 'pct_minus1_sales_pharmacy', (p < 1.0), 'pct=' || round(p, 4) FROM (
        SELECT 100.0 * count(*) FILTER (WHERE "PharmacyKey" = -1) / nullif(count(*), 0) AS p
        FROM sdi."FactPharmacySales")
    UNION ALL
    SELECT 'pct_minus1_sales_date', (p < 1.0), 'pct=' || round(p, 4) FROM (
        SELECT 100.0 * count(*) FILTER (WHERE "DateKey" = -1) / nullif(count(*), 0) AS p
        FROM sdi."FactPharmacySales")
    UNION ALL
    SELECT 'pct_minus1_demand_hospital', (p < 1.0), 'pct=' || round(p, 4) FROM (
        SELECT 100.0 * count(*) FILTER (WHERE "HospitalKey" = -1) / nullif(count(*), 0) AS p
        FROM sdi."FactHospitalDemand")
    UNION ALL
    SELECT 'pct_minus1_demand_medicine', (p < 1.0), 'pct=' || round(p, 4) FROM (
        SELECT 100.0 * count(*) FILTER (WHERE "MedicineKey" = -1) / nullif(count(*), 0) AS p
        FROM sdi."FactHospitalDemand")
    UNION ALL
    SELECT 'pct_minus1_demand_date', (p < 1.0), 'pct=' || round(p, 4) FROM (
        SELECT 100.0 * count(*) FILTER (WHERE "DateKey" = -1) / nullif(count(*), 0) AS p
        FROM sdi."FactHospitalDemand")
) ORDER BY test_name;
