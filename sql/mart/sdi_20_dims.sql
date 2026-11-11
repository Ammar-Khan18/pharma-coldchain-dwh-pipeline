-- =====================================================================
-- sdi_20_dims.sql  —  Phase 1 transform, STEP 2: load dimensions (DuckDB)
-- WBS 3.1. Reads the cleaned staging tables from sdi_10_validate and upserts the
-- SDI dimensions. dim_date and dim_channel are already populated by
-- sdi_01_create_schema.sql and are only reused here.
--
--   dim_medicine        SCD Type 2  — new version only when a tracked attribute
--                                     (price/cost, status, Rx class, cold chain,
--                                     storage limits) changes; names are Type 1.
--   dim_pharmacy        SCD Type 1  — overwrite attributes (built from 05).
--   dim_hospital        SCD Type 1  — overwrite attributes (built from 06),
--                                     bed_size_band derived.
--   dim_sales_profile   junk        — insert new flag combinations only.
--   dim_demand_status   junk        — insert new combinations only.
--
-- The -1 "Unknown / Not applicable" members stay as seeded; they are never
-- touched here. The transform run id is (SELECT etl_batch_id FROM stg._batch).
-- =====================================================================

-- ---------------------------------------------------------------------
-- dim_medicine  (SCD Type 2)
-- ---------------------------------------------------------------------
-- (1) Close the current version of any medicine whose tracked attributes changed.
UPDATE sdi.dim_medicine AS d
SET is_current = FALSE,
    valid_to   = (SELECT run_date FROM stg._batch)
FROM stg._clean_master AS c
WHERE d.medicine_id = c.medicine_id
  AND d.is_current
  AND d.medicine_key <> -1
  AND d.scd2_hash IS DISTINCT FROM c.scd2_hash;

-- (2) Insert a new current version for brand-new medicines and for changed ones
--     (which, after step 1, no longer have a current row). A brand-new medicine
--     starts its history at its EffectiveFromDate; a changed one at the run date.
INSERT INTO sdi.dim_medicine
    (medicine_id, internal_sku, gtin14, generic_name, brand_name, disease_category,
     icd10_category, atc_code, therapeutic_class, dosage_form, strength,
     route_of_administration, pack_size, base_unit_of_measure, prescription_class,
     controlled_medicine_flag, cold_chain_flag, storage_min_temp_c, storage_max_temp_c,
     max_humidity_pct, shelf_life_months, min_remaining_shelf_life_days, primary_supplier_id,
     primary_plant_id, manufacturing_lead_time_days, standard_batch_size_packs,
     safety_stock_days, reorder_review_cycle_days, unit_manufacturing_cost_usd,
     wholesale_price_usd, recommended_retail_price_usd, product_status, scd2_hash,
     valid_from, valid_to, is_current, etl_batch_id)
SELECT c.medicine_id, c.internal_sku, c.gtin14, c.generic_name, c.brand_name, c.disease_category,
       c.icd10_category, c.atc_code, c.therapeutic_class, c.dosage_form, c.strength,
       c.route_of_administration, c.pack_size, c.base_unit_of_measure, c.prescription_class,
       c.controlled_medicine_flag, c.cold_chain_flag, c.storage_min_temp_c, c.storage_max_temp_c,
       c.max_humidity_pct, c.shelf_life_months, c.min_remaining_shelf_life_days, c.primary_supplier_id,
       c.primary_plant_id, c.manufacturing_lead_time_days, c.standard_batch_size_packs,
       c.safety_stock_days, c.reorder_review_cycle_days, c.unit_manufacturing_cost_usd,
       c.wholesale_price_usd, c.recommended_retail_price_usd, c.product_status, c.scd2_hash,
       CASE WHEN ever.medicine_id IS NULL
            THEN COALESCE(c.effective_from_date, (SELECT run_date FROM stg._batch))
            ELSE (SELECT run_date FROM stg._batch) END AS valid_from,
       DATE '9999-12-31', TRUE, (SELECT etl_batch_id FROM stg._batch)
FROM stg._clean_master AS c
LEFT JOIN (SELECT DISTINCT medicine_id FROM sdi.dim_medicine WHERE medicine_key <> -1) AS ever
       ON ever.medicine_id = c.medicine_id
WHERE NOT EXISTS (
    SELECT 1 FROM sdi.dim_medicine d
    WHERE d.medicine_id = c.medicine_id AND d.is_current AND d.medicine_key <> -1
);

-- (3) Type-1 overwrite of descriptive (non-tracked) attributes on unchanged rows.
UPDATE sdi.dim_medicine AS d
SET internal_sku = c.internal_sku, gtin14 = c.gtin14, generic_name = c.generic_name,
    brand_name = c.brand_name, disease_category = c.disease_category,
    icd10_category = c.icd10_category, atc_code = c.atc_code,
    therapeutic_class = c.therapeutic_class, dosage_form = c.dosage_form,
    strength = c.strength, route_of_administration = c.route_of_administration,
    loaded_at = current_timestamp
FROM stg._clean_master AS c
WHERE d.medicine_id = c.medicine_id
  AND d.is_current
  AND d.medicine_key <> -1
  AND d.scd2_hash IS NOT DISTINCT FROM c.scd2_hash;

-- ---------------------------------------------------------------------
-- dim_pharmacy  (SCD Type 1) — distinct pharmacies in this batch's clean sales
-- ---------------------------------------------------------------------
INSERT INTO sdi.dim_pharmacy
    (pharmacy_id, pharmacy_gln, pharmacy_name, pharmacy_type, linked_hospital_id,
     city, state, country_code, etl_batch_id)
SELECT pharmacy_id,
       any_value(pharmacy_gln), any_value(pharmacy_name), any_value(pharmacy_type),
       max(hospital_id),                         -- filled only for hospital pharmacies
       any_value(pharmacy_city), any_value(pharmacy_state), any_value(country_code),
       (SELECT etl_batch_id FROM stg._batch)
FROM stg._clean_sales
GROUP BY pharmacy_id
ON CONFLICT (pharmacy_id) DO UPDATE SET
    pharmacy_gln = excluded.pharmacy_gln, pharmacy_name = excluded.pharmacy_name,
    pharmacy_type = excluded.pharmacy_type, linked_hospital_id = excluded.linked_hospital_id,
    city = excluded.city, state = excluded.state, country_code = excluded.country_code,
    etl_batch_id = excluded.etl_batch_id, updated_at = CAST(now() AS TIMESTAMP);

-- ---------------------------------------------------------------------
-- dim_hospital  (SCD Type 1) — distinct hospitals in this batch's clean demand
-- ---------------------------------------------------------------------
INSERT INTO sdi.dim_hospital
    (hospital_id, hospital_gln, hospital_name, hospital_type, hospital_pharmacy_id,
     city, state, country_code, licensed_beds, icu_beds, avg_occupancy_rate_pct,
     trauma_level, catchment_population, bed_size_band, etl_batch_id)
SELECT hospital_id,
       any_value(hospital_gln), any_value(hospital_name), any_value(hospital_type),
       any_value(hospital_pharmacy_id), any_value(city), any_value(state),
       any_value(country_code), any_value(licensed_beds), any_value(icu_beds),
       any_value(avg_occupancy_rate_pct), any_value(trauma_level),
       any_value(catchment_population),
       CASE WHEN any_value(licensed_beds) < 400 THEN 'Small'
            WHEN any_value(licensed_beds) < 700 THEN 'Medium' ELSE 'Large' END,
       (SELECT etl_batch_id FROM stg._batch)
FROM stg._clean_demand
GROUP BY hospital_id
ON CONFLICT (hospital_id) DO UPDATE SET
    hospital_gln = excluded.hospital_gln, hospital_name = excluded.hospital_name,
    hospital_type = excluded.hospital_type, hospital_pharmacy_id = excluded.hospital_pharmacy_id,
    city = excluded.city, state = excluded.state, country_code = excluded.country_code,
    licensed_beds = excluded.licensed_beds, icu_beds = excluded.icu_beds,
    avg_occupancy_rate_pct = excluded.avg_occupancy_rate_pct, trauma_level = excluded.trauma_level,
    catchment_population = excluded.catchment_population, bed_size_band = excluded.bed_size_band,
    etl_batch_id = excluded.etl_batch_id, updated_at = CAST(now() AS TIMESTAMP);

-- ---------------------------------------------------------------------
-- dim_sales_profile  (junk) — insert new flag combinations only
-- ---------------------------------------------------------------------
INSERT INTO sdi.dim_sales_profile
    (prescription_required_flag, customer_segment, payer_type, payment_method,
     promotion_code, has_promotion, ecommerce_delivery_status, return_flag,
     sale_status, delivery_otif_flag)
SELECT DISTINCT prescription_required_flag, customer_segment, payer_type, payment_method,
       promotion_code, has_promotion, ecommerce_delivery_status, return_flag,
       sale_status, delivery_otif_flag
FROM stg._clean_sales
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- dim_demand_status  (junk) — insert new combinations only
-- ---------------------------------------------------------------------
INSERT INTO sdi.dim_demand_status (medication_request_status, formulary_status)
SELECT DISTINCT medication_request_status, formulary_status
FROM stg._clean_demand
ON CONFLICT DO NOTHING;
