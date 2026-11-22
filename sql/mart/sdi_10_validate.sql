-- =====================================================================
-- sdi_10_validate.sql  —  Phase 1 transform STEP 1: validate + clean (DuckDB)
-- WBS 3.2.2. Runs inside the DuckDB mart with Postgres attached as `pg`.
-- Excel-aligned rewrite (see docs/excel_alignment_plan.md).
--
--   REJECT -> row never enters the mart; staged in stg._rejected -> ods.rejected_rows.
--   WARN   -> row loads; the per-rule count goes to stg._dq -> meta.dq_log.
-- Every rule logs rows_checked / rows_failed per run to stg._dq.
--
-- Reads ODS straight from Postgres (pg.ods.*). Processes only NEW rows:
--   * sales whose SalesTransactionID is not already in FactPharmacySales
--   * demand whose (HospitalID, MedicineID, DemandMonth) is not already loaded
-- Master is small, so its latest snapshot per InternalSKU is re-shaped every run.
--
-- Produces the clean, FINAL-SHAPED staging tables the dim/fact steps consume:
--   stg._clean_master   (one row per InternalSKU; DimMedicine-shaped + prices)
--   stg._clean_sales    (FactPharmacySales-shaped, new rows only)
--   stg._clean_demand   (FactHospitalDemand-shaped, new rows only)
--   stg._rejected, stg._dq, stg._recon
-- Reads seeds via getvariable('seed_dir') (the DAG SET VARIABLEs it; sdi_01 defaults it).
-- The transform run id is (SELECT etl_batch_id FROM stg._batch).
-- =====================================================================

CREATE OR REPLACE TABLE stg._rejected (
    source_table VARCHAR, natural_key VARCHAR, rule_id VARCHAR,
    reason VARCHAR, raw_row VARCHAR, etl_batch_id VARCHAR
);
CREATE OR REPLACE TABLE stg._dq (
    etl_batch_id VARCHAR, source_file VARCHAR, rule_id VARCHAR,
    rule_action VARCHAR, rows_checked BIGINT, rows_failed BIGINT
);
CREATE OR REPLACE TABLE stg._recon (
    source_table VARCHAR, attempted_new BIGINT, rejected_cnt BIGINT, clean_cnt BIGINT
);

-- =====================================================================
-- 01 MASTER -> stg._clean_master     REJECT M1,M2,M4,M5,M6 ; WARN M3, SL
-- =====================================================================
CREATE OR REPLACE TABLE stg._med_eval AS
WITH ranked AS (
    SELECT s.*, CAST(to_json(s) AS VARCHAR) AS raw_json,
           row_number() OVER (PARTITION BY s."InternalSKU" ORDER BY s.loaded_at DESC) AS rn
    FROM pg.ods.master_data s
),
inc AS (
    SELECT
        "InternalSKU" AS internal_sku,
        "MedicineID"  AS medicine_id,
        lpad("GTIN14", 14, '0') AS gtin14,
        "GenericName" AS med_name,
        "TherapeuticClass" AS therapeutic_class,
        "DiseaseCategory"  AS disease_category,
        "ICD10Category"    AS icd10_category,
        "DosageForm"  AS dosage_form,
        "Strength"    AS strength,
        "RouteOfAdministration" AS route,
        TRY_CAST("PackSize" AS INTEGER) AS pack_size_num,
        "BaseUnitOfMeasure" AS base_uom_raw,
        "PrescriptionClass" AS pres_class,
        upper("ColdChainFlag") AS cold_chain_flag,
        upper("ControlledMedicineFlag") AS controlled_med_flag,
        TRY_CAST("ShelfLifeMonths" AS INTEGER) AS shelf_life_months,
        "ProductStatus" AS product_status,
        TRY_CAST("EffectiveFromDate" AS DATE) AS effective_from_date,
        TRY_CAST("UnitManufacturingCostUSD" AS DECIMAL(12,2)) AS mfg_cost,
        TRY_CAST("WholesalePriceUSD"        AS DECIMAL(12,2)) AS mrp,
        TRY_CAST("RecommendedRetailPriceUSD" AS DECIMAL(12,2)) AS list_trade_price,
        raw_json
    FROM ranked WHERE rn = 1
),
derive AS (
    SELECT i.*,
        -- DosageStrength = seed abbrev(DosageForm) (fallback UPPER(first 3)) + ' ' + Strength
        coalesce(d.abbrev, upper(left(i.dosage_form, 3))) || ' ' || coalesce(i.strength, '') AS dosage_strength,
        CASE WHEN i.pack_size_num > 15 THEN 'Large' ELSE 'Small' END AS pack_size,
        -- BaseUOM -> Pack / Device (proper case)
        upper(left(i.base_uom_raw, 1)) || lower(substr(i.base_uom_raw, 2)) AS base_uom,
        -- ShelfLife band; 25..35 falls to the nearer bound and raises a WARN
        CASE WHEN i.shelf_life_months <= 24 THEN 'Short.SL'
             WHEN i.shelf_life_months >= 36 THEN 'Long.SL'
             WHEN i.shelf_life_months - 24 <= 36 - i.shelf_life_months THEN 'Short.SL'
             ELSE 'Long.SL' END AS shelf_life,
        (i.shelf_life_months IS NOT NULL
         AND i.shelf_life_months <> 24 AND i.shelf_life_months <> 36)::INT AS w_sl
    FROM inc i
    LEFT JOIN sdi.seed_dosage_form_abbrev d ON d.dosage_form = i.dosage_form
),
flags AS (
    SELECT *,
        (internal_sku IS NULL OR internal_sku = '')::INT AS r_m1,
        (mfg_cost IS NULL OR mfg_cost <= 0 OR mrp IS NULL OR mrp <= 0
         OR list_trade_price IS NULL OR list_trade_price <= 0)::INT AS r_m2,
        (shelf_life_months IS NULL)::INT AS r_m_nullshelf,   -- informational, not a reject
        (pres_class NOT IN ('Prescription','OTC')
         OR cold_chain_flag NOT IN ('Y','N')
         OR controlled_med_flag NOT IN ('Y','N'))::INT AS r_m5,
        (NOT regexp_full_match(gtin14, '[0-9]{14}'))::INT AS r_m6,
        (mfg_cost IS NULL OR mrp IS NULL)::INT AS r_m4_na,
        (NOT (mfg_cost <= mrp AND mrp <= list_trade_price))::INT AS w_m3
    FROM derive
)
SELECT *,
    CASE WHEN r_m1 = 1 THEN 'M1' WHEN r_m2 = 1 THEN 'M2'
         WHEN r_m5 = 1 THEN 'M5' WHEN r_m6 = 1 THEN 'M6' ELSE NULL END AS reject_rule
FROM flags;

CREATE OR REPLACE TABLE stg._clean_master AS
SELECT internal_sku, medicine_id, gtin14, med_name, therapeutic_class, disease_category,
       icd10_category, dosage_strength, route, pack_size, base_uom, pres_class,
       cold_chain_flag, controlled_med_flag, shelf_life, product_status,
       effective_from_date, mfg_cost, mrp, list_trade_price
FROM stg._med_eval WHERE reject_rule IS NULL;

-- MedicineIDs sales (S2) and demand (H4) may reference: current in DimMedicine
-- plus this run's cleaned master.
CREATE OR REPLACE TABLE stg._valid_medicine_ids AS
SELECT "MedicineID" AS medicine_id FROM sdi."DimMedicine" WHERE "IsCurrent" = 'Y' AND "MedicineID" <> 'UNKNOWN'
UNION
SELECT medicine_id FROM stg._clean_master;

INSERT INTO stg._rejected
SELECT 'ods.master_data', internal_sku, reject_rule,
       CASE reject_rule
           WHEN 'M1' THEN 'InternalSKU empty'
           WHEN 'M2' THEN 'manufacturing cost / wholesale / RRP must be > 0'
           WHEN 'M5' THEN 'flag not Y/N or PrescriptionClass not Prescription/OTC'
           WHEN 'M6' THEN 'GTIN14 must be 14 digits' END,
       raw_json, (SELECT etl_batch_id FROM stg._batch)
FROM stg._med_eval WHERE reject_rule IS NOT NULL;

INSERT INTO stg._dq
WITH b AS (SELECT etl_batch_id FROM stg._batch), n AS (SELECT count(*) c FROM stg._med_eval)
SELECT b.etl_batch_id, 'ods.master_data', x.rule_id, x.rule_action, (SELECT c FROM n), x.failed
FROM b, (
    SELECT 'M1' rule_id, 'REJECT' rule_action, SUM(r_m1) failed FROM stg._med_eval
    UNION ALL SELECT 'M2','REJECT', SUM(r_m2) FROM stg._med_eval
    UNION ALL SELECT 'M3','WARN',   SUM(w_m3) FROM stg._med_eval
    UNION ALL SELECT 'M5','REJECT', SUM(r_m5) FROM stg._med_eval
    UNION ALL SELECT 'M6','REJECT', SUM(r_m6) FROM stg._med_eval
    UNION ALL SELECT 'SL','WARN',   SUM(w_sl) FROM stg._med_eval
) x;

INSERT INTO stg._recon
SELECT 'ods.master_data', count(*),
       count(*) FILTER (WHERE reject_rule IS NOT NULL),
       count(*) FILTER (WHERE reject_rule IS NULL)
FROM stg._med_eval;

-- =====================================================================
-- 05 PHARMACY SALES -> stg._clean_sales   (FactPharmacySales-shaped)
--   REJECT S1,S2,S3,S4,S6,S7 ; WARN S5,S8–S15
--   New rows only: SalesTransactionID not already in FactPharmacySales.
-- =====================================================================
CREATE OR REPLACE TABLE stg._sales_eval AS
WITH ranked AS (
    SELECT s.*, CAST(to_json(s) AS VARCHAR) AS raw_json,
           row_number() OVER (PARTITION BY s."SalesTransactionID" ORDER BY s.loaded_at DESC) AS rn
    FROM pg.ods.pharmacy_sales s
    WHERE s."SalesTransactionID" NOT IN (SELECT "SalesTransactionID" FROM sdi."FactPharmacySales")
      AND s."SalesTransactionID" NOT IN (
          SELECT natural_key FROM pg.ods.rejected_rows
          WHERE source_table = 'ods.pharmacy_sales' AND natural_key IS NOT NULL)
),
inc AS (
    SELECT
        "SalesTransactionID" AS sales_transaction_id,
        TRY_CAST("SalesDate" AS DATE) AS sales_date,
        TRY_CAST(regexp_replace("SalesTimestampUTC", 'Z$', '') AS TIMESTAMP) AS sales_ts,
        "SalesChannel" AS sales_channel,
        "PharmacyID"   AS pharmacy_id,
        "PharmacyType" AS pharmacy_type,
        NULLIF("HospitalID", '') AS hospital_id,
        "MedicineID"   AS medicine_id,
        "CustomerSegment" AS customer_segment,
        TRY_CAST("PharmacyDeliveryDate" AS DATE) AS pharmacy_delivery_date,
        TRY_CAST("BatchExpiryDate" AS DATE) AS batch_expiry_date,
        TRY_CAST("DaysToExpiryAtSale" AS INTEGER) AS days_to_expiry_at_sale,
        TRY_CAST("QuantitySoldPacks" AS INTEGER) AS quantity_sold,
        TRY_CAST("ReturnedQuantityPacks" AS INTEGER) AS returned_qty,
        "ReturnFlag" AS return_flag,
        TRY_CAST("UnitRetailPriceUSD" AS DECIMAL(12,2)) AS unit_retail_price,
        TRY_CAST("GrossSalesAmountUSD" AS DECIMAL(12,2)) AS gross_sales,
        TRY_CAST("DiscountAmountUSD"  AS DECIMAL(12,2)) AS discount,
        TRY_CAST("SalesTaxUSD"        AS DECIMAL(12,2)) AS sales_tax,
        TRY_CAST("CostOfGoodsSoldUSD" AS DECIMAL(12,2)) AS cogs,
        TRY_CAST("NetSalesAmountUSD"  AS DECIMAL(12,2)) AS src_net,
        TRY_CAST("GrossMarginUSD"     AS DECIMAL(12,2)) AS src_margin,
        "PrescriptionRequiredFlag" AS prescription_required_flag,
        NULLIF("PrescriptionID", '') AS prescription_id,
        etl_batch_id AS src_etl_batch_id,
        raw_json
    FROM ranked WHERE rn = 1
),
calc AS (
    SELECT *,
        (gross_sales - discount) AS net_sales,
        (gross_sales - discount - cogs) AS gross_margin
    FROM inc
),
flags AS (
    SELECT *,
        (sales_transaction_id IS NULL OR sales_transaction_id = '')::INT AS r_s1,
        (medicine_id IS NULL OR medicine_id = ''
         OR medicine_id NOT IN (SELECT medicine_id FROM stg._valid_medicine_ids))::INT AS r_s2,
        (pharmacy_id IS NULL OR pharmacy_id = '')::INT AS r_s3,
        (sales_date IS NULL OR sales_date < DATE '2023-01-01'
         OR sales_date > (SELECT run_date FROM stg._batch))::INT AS r_s4,
        (unit_retail_price IS NULL OR unit_retail_price <= 0)::INT AS r_s6,
        (quantity_sold IS NULL OR quantity_sold < 1)::INT AS r_s7,
        (sales_date <> CAST(sales_ts AS DATE))::INT AS w_s5,
        (abs(gross_sales - unit_retail_price * quantity_sold) > 0.01)::INT AS w_s8,
        (abs(src_net - (gross_sales - discount)) > 0.01
         OR discount < 0 OR discount > gross_sales)::INT AS w_s9,
        (abs(src_margin - (gross_sales - discount - cogs)) > 0.01)::INT AS w_s10,
        (returned_qty IS NULL OR returned_qty < 0 OR returned_qty > quantity_sold
         OR ((return_flag = 'Y') <> (returned_qty > 0)))::INT AS w_s11,
        (pharmacy_delivery_date > sales_date)::INT AS w_s12,
        (prescription_required_flag = 'Y' AND prescription_id IS NULL)::INT AS w_s13,
        (batch_expiry_date < sales_date)::INT AS w_s14,
        ((hospital_id IS NOT NULL) <> (pharmacy_type = 'Hospital Pharmacy'))::INT AS w_s15
    FROM calc
)
SELECT *,
    CASE WHEN r_s1 = 1 THEN 'S1' WHEN r_s2 = 1 THEN 'S2' WHEN r_s3 = 1 THEN 'S3'
         WHEN r_s4 = 1 THEN 'S4' WHEN r_s6 = 1 THEN 'S6' WHEN r_s7 = 1 THEN 'S7'
         ELSE NULL END AS reject_rule
FROM flags;

CREATE OR REPLACE TABLE stg._clean_sales AS
SELECT sales_transaction_id, sales_date, sales_channel, pharmacy_id, medicine_id,
       customer_segment, quantity_sold, returned_qty, gross_sales, discount,
       net_sales, sales_tax, cogs, gross_margin, days_to_expiry_at_sale,
       src_etl_batch_id
FROM stg._sales_eval WHERE reject_rule IS NULL;

INSERT INTO stg._rejected
SELECT 'ods.pharmacy_sales', sales_transaction_id, reject_rule,
       CASE reject_rule
           WHEN 'S1' THEN 'SalesTransactionID empty'
           WHEN 'S2' THEN 'MedicineID empty or not in DimMedicine'
           WHEN 'S3' THEN 'PharmacyID empty'
           WHEN 'S4' THEN 'SalesDate invalid or out of range'
           WHEN 'S6' THEN 'UnitRetailPriceUSD must be > 0'
           WHEN 'S7' THEN 'QuantitySoldPacks must be >= 1' END,
       raw_json, (SELECT etl_batch_id FROM stg._batch)
FROM stg._sales_eval WHERE reject_rule IS NOT NULL;

INSERT INTO stg._dq
WITH b AS (SELECT etl_batch_id FROM stg._batch), n AS (SELECT count(*) c FROM stg._sales_eval)
SELECT b.etl_batch_id, 'ods.pharmacy_sales', x.rule_id, x.rule_action, (SELECT c FROM n), x.failed
FROM b, (
    SELECT 'S1' rule_id, 'REJECT' rule_action, SUM(r_s1) failed FROM stg._sales_eval
    UNION ALL SELECT 'S2','REJECT', SUM(r_s2) FROM stg._sales_eval
    UNION ALL SELECT 'S3','REJECT', SUM(r_s3) FROM stg._sales_eval
    UNION ALL SELECT 'S4','REJECT', SUM(r_s4) FROM stg._sales_eval
    UNION ALL SELECT 'S6','REJECT', SUM(r_s6) FROM stg._sales_eval
    UNION ALL SELECT 'S7','REJECT', SUM(r_s7) FROM stg._sales_eval
    UNION ALL SELECT 'S5','WARN',  SUM(w_s5)  FROM stg._sales_eval
    UNION ALL SELECT 'S8','WARN',  SUM(w_s8)  FROM stg._sales_eval
    UNION ALL SELECT 'S9','WARN',  SUM(w_s9)  FROM stg._sales_eval
    UNION ALL SELECT 'S10','WARN', SUM(w_s10) FROM stg._sales_eval
    UNION ALL SELECT 'S11','WARN', SUM(w_s11) FROM stg._sales_eval
    UNION ALL SELECT 'S12','WARN', SUM(w_s12) FROM stg._sales_eval
    UNION ALL SELECT 'S13','WARN', SUM(w_s13) FROM stg._sales_eval
    UNION ALL SELECT 'S14','WARN', SUM(w_s14) FROM stg._sales_eval
    UNION ALL SELECT 'S15','WARN', SUM(w_s15) FROM stg._sales_eval
) x;

INSERT INTO stg._recon
SELECT 'ods.pharmacy_sales', count(*),
       count(*) FILTER (WHERE reject_rule IS NOT NULL),
       count(*) FILTER (WHERE reject_rule IS NULL)
FROM stg._sales_eval;

-- =====================================================================
-- 06 HOSPITAL DEMAND -> stg._clean_demand   (FactHospitalDemand-shaped)
--   REJECT H1,H2,H3,H4,H5,H8,H9 ; WARN H6,H7
--   New rows only: (HospitalID, MedicineID, DemandMonth) not already loaded.
-- =====================================================================
CREATE OR REPLACE TABLE stg._demand_eval AS
WITH ranked AS (
    SELECT s.*, CAST(to_json(s) AS VARCHAR) AS raw_json,
           row_number() OVER (PARTITION BY s."HospitalDemandRecordID" ORDER BY s.loaded_at DESC) AS rn
    FROM pg.ods.hospital_demand s
    WHERE s."HospitalDemandRecordID" NOT IN (
          SELECT natural_key FROM pg.ods.rejected_rows
          WHERE source_table = 'ods.hospital_demand' AND natural_key IS NOT NULL)
      AND NOT EXISTS (
          SELECT 1 FROM sdi."FactHospitalDemand" f
          JOIN sdi."DimHospital" h ON h."HospitalKey" = f."HospitalKey"
          JOIN sdi."DimMedicine" m ON m."MedicineKey" = f."MedicineKey"
          WHERE h."HospitalID" = s."HospitalID"
            AND m."MedicineID" = s."MedicineID"
            AND f."DateKey" = CAST(strftime(TRY_CAST(s."DemandMonth" AS DATE), '%Y%m%d') AS INTEGER))
),
inc AS (
    SELECT
        "HospitalDemandRecordID" AS hospital_demand_record_id,
        TRY_CAST("DemandMonth" AS DATE) AS demand_month,
        "HospitalID" AS hospital_id,
        lpad("GTIN14", 14, '0') AS gtin14,
        "MedicineID" AS medicine_id,
        TRY_CAST("AverageOccupancyRatePct" AS DECIMAL(5,2)) AS occupancy_pct,
        TRY_CAST("ICUBeds" AS INTEGER) AS icu_beds,
        TRY_CAST("LicensedBeds" AS INTEGER) AS licensed_beds,
        TRY_CAST("EstimatedDiseaseCases" AS INTEGER) AS estimated_disease_cases,
        TRY_CAST("DiseaseRelatedAdmissions" AS INTEGER) AS disease_related_admissions,
        TRY_CAST("OutpatientEncounters" AS INTEGER) AS outpatient_encounters,
        TRY_CAST("ForecastDemandPacks" AS INTEGER) AS forecast_demand,
        TRY_CAST("RequestedQuantityPacks" AS INTEGER) AS requested_qty,
        TRY_CAST("ApprovedQuantityPacks" AS INTEGER) AS approved_qty,
        TRY_CAST("ReceivedQuantityPacks" AS INTEGER) AS received_qty,
        TRY_CAST("EmergencyRequestQuantityPacks" AS INTEGER) AS emergency_request_qty,
        TRY_CAST("OpeningStockPacks" AS INTEGER) AS opening_stock,
        TRY_CAST("DispensedQuantityPacks" AS INTEGER) AS dispensed_qty,
        TRY_CAST("ConsumedQuantityPacks" AS INTEGER) AS consumed_qty,
        TRY_CAST("WastageQuantityPacks" AS INTEGER) AS wastage_qty,
        TRY_CAST("ClosingStockPacks" AS INTEGER) AS closing_stock,
        TRY_CAST("UnfulfilledDemandPacks" AS INTEGER) AS unfulfilled_demand,
        TRY_CAST("StockoutDays" AS INTEGER) AS stockout_days,
        TRY_CAST("ServiceLevelPct" AS DECIMAL(6,2)) AS service_level_pct,
        TRY_CAST("DemandTrendIndex" AS DECIMAL(6,3)) AS demand_trend_index,
        etl_batch_id AS src_etl_batch_id,
        raw_json
    FROM ranked WHERE rn = 1
),
flags AS (
    SELECT *,
        count(*) OVER (PARTITION BY hospital_id, medicine_id, demand_month) AS grain_n,
        (hospital_demand_record_id IS NULL OR hospital_demand_record_id = '')::INT AS r_h1,
        (demand_month IS NULL OR day(demand_month) <> 1
         OR demand_month < DATE '2023-01-01'
         OR demand_month > date_trunc('month', (SELECT run_date FROM stg._batch)))::INT AS r_h3,
        (medicine_id IS NULL OR medicine_id = ''
         OR medicine_id NOT IN (SELECT medicine_id FROM stg._valid_medicine_ids)
         OR hospital_id IS NULL OR hospital_id = '')::INT AS r_h4,
        (least(forecast_demand, requested_qty, approved_qty, received_qty,
               emergency_request_qty, opening_stock, dispensed_qty, consumed_qty,
               wastage_qty, closing_stock, unfulfilled_demand, stockout_days) < 0)::INT AS r_h5,
        (service_level_pct IS NULL OR service_level_pct < 0 OR service_level_pct > 100)::INT AS r_h8,
        (stockout_days IS NULL OR stockout_days < 0
         OR stockout_days > day(last_day(demand_month)))::INT AS r_h9,
        (approved_qty > requested_qty OR received_qty > approved_qty)::INT AS w_h6,
        (closing_stock <> opening_stock + received_qty - dispensed_qty - wastage_qty)::INT AS w_h7
    FROM inc
)
SELECT *,
    (grain_n > 1)::INT AS r_h2,
    CASE WHEN (hospital_demand_record_id IS NULL OR hospital_demand_record_id = '') THEN 'H1'
         WHEN grain_n > 1 THEN 'H2'
         WHEN r_h3 = 1 THEN 'H3' WHEN r_h4 = 1 THEN 'H4' WHEN r_h5 = 1 THEN 'H5'
         WHEN r_h8 = 1 THEN 'H8' WHEN r_h9 = 1 THEN 'H9' ELSE NULL END AS reject_rule
FROM flags;

CREATE OR REPLACE TABLE stg._clean_demand AS
SELECT hospital_demand_record_id, demand_month, hospital_id, gtin14, medicine_id,
       occupancy_pct, icu_beds, licensed_beds, estimated_disease_cases,
       disease_related_admissions, outpatient_encounters, forecast_demand, requested_qty,
       approved_qty, emergency_request_qty, opening_stock, dispensed_qty, consumed_qty,
       wastage_qty, closing_stock, unfulfilled_demand, stockout_days, demand_trend_index,
       src_etl_batch_id
FROM stg._demand_eval WHERE reject_rule IS NULL;

INSERT INTO stg._rejected
SELECT 'ods.hospital_demand', hospital_demand_record_id, reject_rule,
       CASE reject_rule
           WHEN 'H1' THEN 'HospitalDemandRecordID empty'
           WHEN 'H2' THEN '(HospitalID, MedicineID, DemandMonth) not unique'
           WHEN 'H3' THEN 'DemandMonth invalid, not 1st of month, or out of range'
           WHEN 'H4' THEN 'MedicineID not in DimMedicine or HospitalID empty'
           WHEN 'H5' THEN 'a quantity is negative'
           WHEN 'H8' THEN 'ServiceLevelPct out of 0..100'
           WHEN 'H9' THEN 'StockoutDays out of 0..days-in-month' END,
       raw_json, (SELECT etl_batch_id FROM stg._batch)
FROM stg._demand_eval WHERE reject_rule IS NOT NULL;

INSERT INTO stg._dq
WITH b AS (SELECT etl_batch_id FROM stg._batch), n AS (SELECT count(*) c FROM stg._demand_eval)
SELECT b.etl_batch_id, 'ods.hospital_demand', x.rule_id, x.rule_action, (SELECT c FROM n), x.failed
FROM b, (
    SELECT 'H1' rule_id, 'REJECT' rule_action, SUM(r_h1) failed FROM stg._demand_eval
    UNION ALL SELECT 'H2','REJECT', SUM(r_h2) FROM stg._demand_eval
    UNION ALL SELECT 'H3','REJECT', SUM(r_h3) FROM stg._demand_eval
    UNION ALL SELECT 'H4','REJECT', SUM(r_h4) FROM stg._demand_eval
    UNION ALL SELECT 'H5','REJECT', SUM(r_h5) FROM stg._demand_eval
    UNION ALL SELECT 'H8','REJECT', SUM(r_h8) FROM stg._demand_eval
    UNION ALL SELECT 'H9','REJECT', SUM(r_h9) FROM stg._demand_eval
    UNION ALL SELECT 'H6','WARN',  SUM(w_h6)  FROM stg._demand_eval
    UNION ALL SELECT 'H7','WARN',  SUM(w_h7)  FROM stg._demand_eval
) x;

INSERT INTO stg._recon
SELECT 'ods.hospital_demand', count(*),
       count(*) FILTER (WHERE reject_rule IS NOT NULL),
       count(*) FILTER (WHERE reject_rule IS NULL)
FROM stg._demand_eval;
