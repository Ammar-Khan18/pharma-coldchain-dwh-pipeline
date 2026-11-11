-- =====================================================================
-- sdi_10_validate.sql  —  Phase 1 transform, STEP 1: validate + clean (DuckDB)
-- WBS 3.2.2. Runs inside the DuckDB mart with Postgres attached as `pg`.
--
-- Applies the design-doc rules (docs/phase1_sdi_design.md section 2):
--   REJECT  -> row never enters the mart; staged in stg._rejected, later copied
--              to Postgres ods.rejected_rows.
--   WARN    -> row loads, but its dq_warning_count goes up; counts go to meta.dq_log.
-- Every rule (REJECT and WARN) logs rows_checked / rows_failed to stg._dq per run.
--
-- Reads ODS straight from Postgres (pg.ods.*) — fast, no copy. Processes only
-- NEW rows: sales/demand whose natural key is not already in the fact. Master is
-- small, so its full current snapshot is re-validated every run (dims are idempotent).
--
-- Outputs (DuckDB staging tables, read by sdi_20_dims / sdi_30_facts / sdi_40_tests
-- and by the Python task that ships _rejected/_dq to Postgres):
--   stg._clean_master, stg._clean_sales, stg._clean_demand
--   stg._rejected, stg._dq, stg._recon
-- The transform run id is read as (SELECT etl_batch_id FROM stg._batch).
-- =====================================================================

-- Collectors (recreated every run) -----------------------------------------
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
-- 01 MASTER -> stg._clean_master     REJECT M1,M2,M4,M5,M6 ; WARN M3
-- =====================================================================
CREATE OR REPLACE TABLE stg._med_eval AS
WITH ranked AS (
    SELECT s.*, CAST(to_json(s) AS VARCHAR) AS raw_json,
           row_number() OVER (PARTITION BY s."MedicineID" ORDER BY s.loaded_at DESC) AS rn
    FROM pg.ods.master_data s
),
inc AS (
    SELECT
        "MedicineID" AS medicine_id, "InternalSKU" AS internal_sku,
        lpad("GTIN14", 14, '0') AS gtin14, "GenericName" AS generic_name,
        "FictionalBrandName" AS brand_name, "DiseaseCategory" AS disease_category,
        "ICD10Category" AS icd10_category, "ATCCode" AS atc_code,
        "TherapeuticClass" AS therapeutic_class, "DosageForm" AS dosage_form,
        "Strength" AS strength, "RouteOfAdministration" AS route_of_administration,
        TRY_CAST("PackSize" AS INTEGER) AS pack_size,
        "BaseUnitOfMeasure" AS base_unit_of_measure,
        "PrescriptionClass" AS prescription_class,
        "ControlledMedicineFlag" AS controlled_medicine_flag,
        "ColdChainFlag" AS cold_chain_flag,
        TRY_CAST("StorageMinTempC" AS INTEGER) AS storage_min_temp_c,
        TRY_CAST("StorageMaxTempC" AS INTEGER) AS storage_max_temp_c,
        TRY_CAST("MaxHumidityPct" AS INTEGER) AS max_humidity_pct,
        TRY_CAST("ShelfLifeMonths" AS INTEGER) AS shelf_life_months,
        TRY_CAST("MinimumRemainingShelfLifeDays" AS INTEGER) AS min_remaining_shelf_life_days,
        "PrimarySupplierID" AS primary_supplier_id, "PrimaryPlantID" AS primary_plant_id,
        TRY_CAST("ManufacturingLeadTimeDays" AS INTEGER) AS manufacturing_lead_time_days,
        TRY_CAST("StandardBatchSizePacks" AS INTEGER) AS standard_batch_size_packs,
        TRY_CAST("SafetyStockDays" AS INTEGER) AS safety_stock_days,
        TRY_CAST("ReorderReviewCycleDays" AS INTEGER) AS reorder_review_cycle_days,
        TRY_CAST("UnitManufacturingCostUSD" AS DECIMAL(12,4)) AS unit_manufacturing_cost_usd,
        TRY_CAST("WholesalePriceUSD" AS DECIMAL(12,4)) AS wholesale_price_usd,
        TRY_CAST("RecommendedRetailPriceUSD" AS DECIMAL(12,4)) AS recommended_retail_price_usd,
        "ProductStatus" AS product_status,
        TRY_CAST("EffectiveFromDate" AS DATE) AS effective_from_date,
        raw_json
    FROM ranked WHERE rn = 1
),
flags AS (
    SELECT *,
        md5(concat_ws('|', unit_manufacturing_cost_usd, wholesale_price_usd,
            recommended_retail_price_usd, product_status, prescription_class,
            cold_chain_flag, storage_min_temp_c, storage_max_temp_c, max_humidity_pct)) AS scd2_hash,
        (medicine_id IS NULL OR medicine_id = '')::INT AS r_m1,
        (unit_manufacturing_cost_usd IS NULL OR unit_manufacturing_cost_usd <= 0
         OR wholesale_price_usd IS NULL OR wholesale_price_usd <= 0
         OR recommended_retail_price_usd IS NULL OR recommended_retail_price_usd <= 0)::INT AS r_m2,
        (storage_min_temp_c IS NULL OR storage_max_temp_c IS NULL
         OR storage_min_temp_c >= storage_max_temp_c)::INT AS r_m4,
        (prescription_class NOT IN ('Prescription','OTC')
         OR controlled_medicine_flag NOT IN ('Y','N')
         OR cold_chain_flag NOT IN ('Y','N'))::INT AS r_m5,
        (NOT regexp_full_match(gtin14, '[0-9]{14}'))::INT AS r_m6,
        (NOT (unit_manufacturing_cost_usd <= wholesale_price_usd
              AND wholesale_price_usd <= recommended_retail_price_usd))::INT AS w_m3
    FROM inc
)
SELECT *,
    CASE WHEN r_m1 = 1 THEN 'M1' WHEN r_m2 = 1 THEN 'M2' WHEN r_m4 = 1 THEN 'M4'
         WHEN r_m5 = 1 THEN 'M5' WHEN r_m6 = 1 THEN 'M6' ELSE NULL END AS reject_rule
FROM flags;

CREATE OR REPLACE TABLE stg._clean_master AS
SELECT * EXCLUDE (raw_json, r_m1, r_m2, r_m4, r_m5, r_m6, w_m3, reject_rule)
FROM stg._med_eval WHERE reject_rule IS NULL;

-- Medicine IDs that sales (S2) and demand (H4) are allowed to reference: those
-- already current in dim_medicine PLUS this run's freshly cleaned master. Built
-- here so sales/demand validation does not depend on dims being built first.
CREATE OR REPLACE TABLE stg._valid_medicine_ids AS
SELECT medicine_id FROM sdi.dim_medicine WHERE is_current AND medicine_id <> 'UNKNOWN'
UNION
SELECT medicine_id FROM stg._clean_master;

INSERT INTO stg._rejected
SELECT 'ods.master_data', medicine_id, reject_rule,
       CASE reject_rule
           WHEN 'M1' THEN 'MedicineID empty'
           WHEN 'M2' THEN 'manufacturing cost / wholesale / RRP must be > 0'
           WHEN 'M4' THEN 'StorageMinTempC must be < StorageMaxTempC'
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
    UNION ALL SELECT 'M4','REJECT', SUM(r_m4) FROM stg._med_eval
    UNION ALL SELECT 'M5','REJECT', SUM(r_m5) FROM stg._med_eval
    UNION ALL SELECT 'M6','REJECT', SUM(r_m6) FROM stg._med_eval
) x;

INSERT INTO stg._recon
SELECT 'ods.master_data', count(*),
       count(*) FILTER (WHERE reject_rule IS NOT NULL),
       count(*) FILTER (WHERE reject_rule IS NULL)
FROM stg._med_eval;

-- =====================================================================
-- 05 PHARMACY SALES -> stg._clean_sales
--   REJECT S1,S2,S3,S4,S6,S7 ; WARN S5,S8–S16
--   New rows only: SalesTransactionID not already in sdi.fact_sales.
-- =====================================================================
CREATE OR REPLACE TABLE stg._sales_eval AS
WITH ranked AS (
    SELECT s.*, CAST(to_json(s) AS VARCHAR) AS raw_json,
           row_number() OVER (PARTITION BY s."SalesTransactionID" ORDER BY s.loaded_at DESC) AS rn
    FROM pg.ods.pharmacy_sales s
    WHERE s."SalesTransactionID" NOT IN (SELECT sales_transaction_id FROM sdi.fact_sales)
),
inc AS (
    SELECT
        "SalesTransactionID" AS sales_transaction_id,
        TRY_CAST("SalesDate" AS DATE) AS sales_date,
        TRY_CAST(regexp_replace("SalesTimestampUTC", 'Z$', '') AS TIMESTAMP) AS sales_ts,
        "SalesChannel" AS sales_channel, "PharmacyID" AS pharmacy_id,
        "PharmacyGLN" AS pharmacy_gln, "PharmacyName" AS pharmacy_name,
        "PharmacyType" AS pharmacy_type,
        NULLIF("HospitalID", '') AS hospital_id,
        "PharmacyCity" AS pharmacy_city, "PharmacyState" AS pharmacy_state,
        "CountryCode" AS country_code,
        "PharmacyOrderID" AS pharmacy_order_id, "PharmacyDeliveryID" AS pharmacy_delivery_id,
        TRY_CAST("PharmacyDeliveryDate" AS DATE) AS pharmacy_delivery_date,
        "DeliveryOTIFFlag" AS delivery_otif_flag,
        "WarehouseLotID" AS warehouse_lot_id, "SourceWarehouseID" AS source_warehouse_id,
        "ProductionBatchID" AS production_batch_id, "MedicineID" AS medicine_id,
        TRY_CAST("BatchExpiryDate" AS DATE) AS batch_expiry_date,
        TRY_CAST("DaysToExpiryAtSale" AS INTEGER) AS days_to_expiry_at_sale,
        TRY_CAST("QuantitySoldPacks" AS INTEGER) AS quantity_sold_packs,
        TRY_CAST("UnitRetailPriceUSD" AS DECIMAL(12,2)) AS unit_retail_price_usd,
        TRY_CAST("GrossSalesAmountUSD" AS DECIMAL(12,2)) AS gross_sales_usd,
        TRY_CAST("DiscountAmountUSD" AS DECIMAL(12,2)) AS discount_usd,
        TRY_CAST("NetSalesAmountUSD" AS DECIMAL(12,2)) AS net_sales_usd,
        TRY_CAST("SalesTaxUSD" AS DECIMAL(12,2)) AS sales_tax_usd,
        TRY_CAST("CostOfGoodsSoldUSD" AS DECIMAL(12,2)) AS cogs_usd,
        TRY_CAST("GrossMarginUSD" AS DECIMAL(12,2)) AS gross_margin_usd,
        CASE WHEN "PromotionCode" IS NULL OR "PromotionCode" = '' THEN 'NONE' ELSE "PromotionCode" END AS promotion_code,
        "PrescriptionRequiredFlag" AS prescription_required_flag,
        NULLIF("PrescriptionID", '') AS prescription_id,
        "CustomerSegment" AS customer_segment, "PayerType" AS payer_type,
        "PaymentMethod" AS payment_method, "EcommerceDeliveryStatus" AS ecommerce_delivery_status,
        "ReturnFlag" AS return_flag,
        TRY_CAST("ReturnedQuantityPacks" AS INTEGER) AS returned_quantity_packs,
        "SaleStatus" AS sale_status, "SourceSystem" AS source_system,
        raw_json
    FROM ranked WHERE rn = 1
),
flags AS (
    SELECT *,
        (promotion_code <> 'NONE') AS has_promotion,
        CASE WHEN sales_channel = 'Ecommerce' THEN 'ECOM'
             WHEN pharmacy_type = 'Hospital Pharmacy' THEN 'HOSPITAL'
             ELSE 'RETAIL' END AS channel_code,
        -- REJECT
        (sales_transaction_id IS NULL OR sales_transaction_id = '')::INT AS r_s1,
        (medicine_id IS NULL OR medicine_id = ''
         OR medicine_id NOT IN (SELECT medicine_id FROM stg._valid_medicine_ids))::INT AS r_s2,
        (pharmacy_id IS NULL OR pharmacy_id = '')::INT AS r_s3,
        (sales_date IS NULL OR sales_date < DATE '2023-01-01'
         OR sales_date > (SELECT run_date FROM stg._batch))::INT AS r_s4,
        (unit_retail_price_usd IS NULL OR unit_retail_price_usd <= 0)::INT AS r_s6,
        (quantity_sold_packs IS NULL OR quantity_sold_packs < 1)::INT AS r_s7,
        -- WARN
        (sales_date <> CAST(sales_ts AS DATE))::INT AS w_s5,
        (abs(gross_sales_usd - unit_retail_price_usd * quantity_sold_packs) > 0.01)::INT AS w_s8,
        (abs(net_sales_usd - (gross_sales_usd - discount_usd)) > 0.01
         OR discount_usd < 0 OR discount_usd > gross_sales_usd)::INT AS w_s9,
        (abs(gross_margin_usd - (net_sales_usd - cogs_usd)) > 0.01)::INT AS w_s10,
        (returned_quantity_packs IS NULL OR returned_quantity_packs < 0
         OR returned_quantity_packs > quantity_sold_packs
         OR ((return_flag = 'Y') <> (returned_quantity_packs > 0)))::INT AS w_s11,
        (pharmacy_delivery_date > sales_date)::INT AS w_s12,
        (prescription_required_flag = 'Y' AND prescription_id IS NULL)::INT AS w_s13,
        (batch_expiry_date < sales_date)::INT AS w_s14,
        ((hospital_id IS NOT NULL) <> (pharmacy_type = 'Hospital Pharmacy'))::INT AS w_s15,
        (sales_channel NOT IN ('Physical Pharmacy','Ecommerce')
         OR pharmacy_type NOT IN ('Chain Pharmacy','Independent Pharmacy','Hospital Pharmacy')
         OR customer_segment NOT IN ('General wellness','Pediatric household','Senior chronic care','Adult acute care','Adult chronic care')
         OR payer_type NOT IN ('Government program','Insurance','Cash','Hospital formulary')
         OR payment_method NOT IN ('Card','Insurance claim','Cash','Digital wallet')
         OR ecommerce_delivery_status NOT IN ('Not applicable','Delivered','Returned to sender')
         OR sale_status NOT IN ('Completed','Partially returned'))::INT AS w_s16
    FROM inc
)
SELECT *,
    CASE WHEN r_s1 = 1 THEN 'S1' WHEN r_s2 = 1 THEN 'S2' WHEN r_s3 = 1 THEN 'S3'
         WHEN r_s4 = 1 THEN 'S4' WHEN r_s6 = 1 THEN 'S6' WHEN r_s7 = 1 THEN 'S7'
         ELSE NULL END AS reject_rule,
    (w_s5 + w_s8 + w_s9 + w_s10 + w_s11 + w_s12 + w_s13 + w_s14 + w_s15 + w_s16) AS dq_warning_count
FROM flags;

CREATE OR REPLACE TABLE stg._clean_sales AS
SELECT * EXCLUDE (raw_json, reject_rule,
       r_s1, r_s2, r_s3, r_s4, r_s6, r_s7,
       w_s5, w_s8, w_s9, w_s10, w_s11, w_s12, w_s13, w_s14, w_s15, w_s16)
FROM stg._sales_eval WHERE reject_rule IS NULL;

INSERT INTO stg._rejected
SELECT 'ods.pharmacy_sales', sales_transaction_id, reject_rule,
       CASE reject_rule
           WHEN 'S1' THEN 'SalesTransactionID empty'
           WHEN 'S2' THEN 'MedicineID empty or not in dim_medicine'
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
    UNION ALL SELECT 'S16','WARN', SUM(w_s16) FROM stg._sales_eval
) x;

INSERT INTO stg._recon
SELECT 'ods.pharmacy_sales', count(*),
       count(*) FILTER (WHERE reject_rule IS NOT NULL),
       count(*) FILTER (WHERE reject_rule IS NULL)
FROM stg._sales_eval;

-- =====================================================================
-- 06 HOSPITAL DEMAND -> stg._clean_demand
--   REJECT H1,H2,H3,H4,H5,H8,H9 ; WARN H6,H7
--   New rows only: HospitalDemandRecordID not already in sdi.fact_hospital_demand.
-- =====================================================================
CREATE OR REPLACE TABLE stg._demand_eval AS
WITH ranked AS (
    SELECT s.*, CAST(to_json(s) AS VARCHAR) AS raw_json,
           row_number() OVER (PARTITION BY s."HospitalDemandRecordID" ORDER BY s.loaded_at DESC) AS rn
    FROM pg.ods.hospital_demand s
    WHERE s."HospitalDemandRecordID" NOT IN (SELECT hospital_demand_record_id FROM sdi.fact_hospital_demand)
),
inc AS (
    SELECT
        "HospitalDemandRecordID" AS hospital_demand_record_id,
        TRY_CAST("DemandMonth" AS DATE) AS demand_month,
        "HospitalID" AS hospital_id, "HospitalGLN" AS hospital_gln,
        "HospitalName" AS hospital_name, "HospitalType" AS hospital_type,
        "HospitalPharmacyID" AS hospital_pharmacy_id, "City" AS city, "State" AS state,
        "CountryCode" AS country_code,
        TRY_CAST("LicensedBeds" AS INTEGER) AS licensed_beds,
        TRY_CAST("ICUBeds" AS INTEGER) AS icu_beds,
        TRY_CAST("AverageOccupancyRatePct" AS INTEGER) AS avg_occupancy_rate_pct,
        CASE WHEN "TraumaLevel" IS NULL OR "TraumaLevel" = '' THEN 'Not designated' ELSE "TraumaLevel" END AS trauma_level,
        TRY_CAST("CatchmentPopulation" AS INTEGER) AS catchment_population,
        "MedicineID" AS medicine_id,
        TRY_CAST("EstimatedDiseaseCases" AS INTEGER) AS estimated_disease_cases,
        TRY_CAST("DiseaseRelatedAdmissions" AS INTEGER) AS disease_related_admissions,
        TRY_CAST("OutpatientEncounters" AS INTEGER) AS outpatient_encounters,
        TRY_CAST("ForecastDemandPacks" AS INTEGER) AS forecast_demand_packs,
        TRY_CAST("RequestedQuantityPacks" AS INTEGER) AS requested_qty_packs,
        TRY_CAST("ApprovedQuantityPacks" AS INTEGER) AS approved_qty_packs,
        TRY_CAST("ReceivedQuantityPacks" AS INTEGER) AS received_qty_packs,
        TRY_CAST("EmergencyRequestQuantityPacks" AS INTEGER) AS emergency_request_qty_packs,
        TRY_CAST("OpeningStockPacks" AS INTEGER) AS opening_stock_packs,
        TRY_CAST("DispensedQuantityPacks" AS INTEGER) AS dispensed_qty_packs,
        TRY_CAST("ConsumedQuantityPacks" AS INTEGER) AS consumed_qty_packs,
        TRY_CAST("WastageQuantityPacks" AS INTEGER) AS wastage_qty_packs,
        TRY_CAST("ClosingStockPacks" AS INTEGER) AS closing_stock_packs,
        TRY_CAST("UnfulfilledDemandPacks" AS INTEGER) AS unfulfilled_demand_packs,
        TRY_CAST("StockoutDays" AS INTEGER) AS stockout_days,
        TRY_CAST("ServiceLevelPct" AS DECIMAL(6,2)) AS service_level_pct,
        TRY_CAST("AverageLeadTimeDays" AS INTEGER) AS avg_lead_time_days,
        TRY_CAST("DemandTrendIndex" AS DECIMAL(8,3)) AS demand_trend_index,
        "MedicationRequestStatus" AS medication_request_status,
        "FormularyStatus" AS formulary_status,
        raw_json
    FROM ranked WHERE rn = 1
),
flags AS (
    SELECT *,
        count(*) OVER (PARTITION BY hospital_id, medicine_id, demand_month) AS grain_n,
        (hospital_demand_record_id IS NULL OR hospital_demand_record_id = '')::INT AS r_h1,
        -- H3: valid month, 1st of month, within range
        (demand_month IS NULL OR day(demand_month) <> 1
         OR demand_month < DATE '2023-01-01'
         OR demand_month > date_trunc('month', (SELECT run_date FROM stg._batch)))::INT AS r_h3,
        (medicine_id IS NULL OR medicine_id = ''
         OR medicine_id NOT IN (SELECT medicine_id FROM stg._valid_medicine_ids)
         OR hospital_id IS NULL OR hospital_id = '')::INT AS r_h4,
        (least(forecast_demand_packs, requested_qty_packs, approved_qty_packs, received_qty_packs,
               emergency_request_qty_packs, opening_stock_packs, dispensed_qty_packs,
               consumed_qty_packs, wastage_qty_packs, closing_stock_packs,
               unfulfilled_demand_packs, stockout_days) < 0)::INT AS r_h5,
        (service_level_pct IS NULL OR service_level_pct < 0 OR service_level_pct > 100)::INT AS r_h8,
        (stockout_days IS NULL OR stockout_days < 0
         OR stockout_days > day(last_day(demand_month)))::INT AS r_h9,
        (approved_qty_packs > requested_qty_packs OR received_qty_packs > approved_qty_packs)::INT AS w_h6,
        (closing_stock_packs <> opening_stock_packs + received_qty_packs
                              - dispensed_qty_packs - wastage_qty_packs)::INT AS w_h7
    FROM inc
)
SELECT *,
    (grain_n > 1)::INT AS r_h2,
    CASE WHEN (hospital_demand_record_id IS NULL OR hospital_demand_record_id = '') THEN 'H1'
         WHEN grain_n > 1 THEN 'H2'
         WHEN r_h3 = 1 THEN 'H3' WHEN r_h4 = 1 THEN 'H4' WHEN r_h5 = 1 THEN 'H5'
         WHEN r_h8 = 1 THEN 'H8' WHEN r_h9 = 1 THEN 'H9' ELSE NULL END AS reject_rule,
    (w_h6 + w_h7) AS dq_warning_count
FROM flags;

CREATE OR REPLACE TABLE stg._clean_demand AS
SELECT * EXCLUDE (raw_json, grain_n, reject_rule,
       r_h1, r_h2, r_h3, r_h4, r_h5, r_h8, r_h9, w_h6, w_h7)
FROM stg._demand_eval WHERE reject_rule IS NULL;

INSERT INTO stg._rejected
SELECT 'ods.hospital_demand', hospital_demand_record_id, reject_rule,
       CASE reject_rule
           WHEN 'H1' THEN 'HospitalDemandRecordID empty'
           WHEN 'H2' THEN '(HospitalID, MedicineID, DemandMonth) not unique'
           WHEN 'H3' THEN 'DemandMonth invalid, not 1st of month, or out of range'
           WHEN 'H4' THEN 'MedicineID not in dim_medicine or HospitalID empty'
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
