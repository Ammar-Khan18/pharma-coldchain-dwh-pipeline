-- =====================================================================
-- sdi_22_dim_medicine.sql  —  Phase 1 transform STEP 2b: DimMedicine (DuckDB)
-- SCD Type 2 ONLY on PresClass and ProductStatus; every other attribute is
-- Type 1 (overwritten in ALL versions of that InternalSKU). Prices are NOT
-- tracked here — they are copied per sale onto FactPharmacySales.
-- Reads stg._clean_master (one row per InternalSKU).
--
-- A new version's EffectiveFrom is the first day of the EARLIEST business month in
-- this ODS batch (min SalesDate / DemandMonth of the rows being processed) — for a
-- generator refresh that is the refresh month (e.g. 2026-02-01), so the new version
-- actually covers the refresh's facts. If the batch has no business date, fall back
-- to the run date. The closed row's EffectiveTo = that date - 1.
-- =====================================================================
CREATE OR REPLACE TABLE stg._change_date AS
SELECT coalesce(
    (SELECT date_trunc('month', min(d))::DATE
     FROM (SELECT min(sales_date) AS d FROM stg._clean_sales
           UNION ALL SELECT min(demand_month) AS d FROM stg._clean_demand) t
     WHERE d IS NOT NULL),
    (SELECT run_date FROM stg._batch)
) AS change_date;

-- (1) Close the current version of any medicine whose PresClass or ProductStatus
--     changed. EffectiveTo = change_date - 1, IsCurrent = 'N'.
UPDATE sdi."DimMedicine" AS d
SET "IsCurrent" = 'N',
    "EffectiveTo" = (SELECT change_date FROM stg._change_date) - 1
FROM stg._clean_master AS c
WHERE d."InternalSKU" = c.internal_sku
  AND d."IsCurrent" = 'Y'
  AND d."MedicineKey" <> -1
  AND (d."PresClass" IS DISTINCT FROM c.pres_class
       OR d."ProductStatus" IS DISTINCT FROM c.product_status);

-- (2) Insert a new current version for brand-new medicines and for changed ones
--     (which no longer have a current row after step 1). Brand-new medicines start
--     at 2023-01-01; a changed version starts at the run date.
INSERT INTO sdi."DimMedicine"
    ("InternalSKU", "MedicineID", "GTIN14", "MedName", "TherapeuticClass",
     "DiseaseCategory", "ICD10Category", "DosageStrength", "Route", "PackSize", "BaseUOM",
     "PresClass", "ColdChainFlag", "ControlledMedFlag", "ShelfLife", "ProductStatus",
     "EffectiveFrom", "EffectiveTo", "IsCurrent")
SELECT c.internal_sku, c.medicine_id, c.gtin14, c.med_name, c.therapeutic_class,
       c.disease_category, c.icd10_category, c.dosage_strength, c.route, c.pack_size, c.base_uom,
       c.pres_class, c.cold_chain_flag, c.controlled_med_flag, c.shelf_life, c.product_status,
       CASE WHEN ever.internal_sku IS NULL
            THEN DATE '2023-01-01'
            ELSE (SELECT change_date FROM stg._change_date) END,
       DATE '9999-12-31', 'Y'
FROM stg._clean_master AS c
LEFT JOIN (SELECT DISTINCT "InternalSKU" AS internal_sku
           FROM sdi."DimMedicine" WHERE "MedicineKey" <> -1) AS ever
       ON ever.internal_sku = c.internal_sku
WHERE NOT EXISTS (
    SELECT 1 FROM sdi."DimMedicine" d
    WHERE d."InternalSKU" = c.internal_sku AND d."IsCurrent" = 'Y' AND d."MedicineKey" <> -1
);

-- (3) Type-1 overwrite of every non-tracked attribute in ALL versions of the SKU.
UPDATE sdi."DimMedicine" AS d
SET "MedicineID" = c.medicine_id, "GTIN14" = c.gtin14, "MedName" = c.med_name,
    "TherapeuticClass" = c.therapeutic_class, "DiseaseCategory" = c.disease_category,
    "ICD10Category" = c.icd10_category, "DosageStrength" = c.dosage_strength,
    "Route" = c.route, "PackSize" = c.pack_size, "BaseUOM" = c.base_uom,
    "ColdChainFlag" = c.cold_chain_flag, "ControlledMedFlag" = c.controlled_med_flag,
    "ShelfLife" = c.shelf_life
FROM stg._clean_master AS c
WHERE d."InternalSKU" = c.internal_sku
  AND d."MedicineKey" <> -1;
