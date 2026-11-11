-- =====================================================================
-- Phase 1 ODS (Operational Data Store) landing tables  —  Postgres schema `ods`
-- File: sql/postgres/02_ods_tables.sql        Run as ida_user. Safe to re-run.
--
-- The ODS is the pipeline's "inbox": it keeps the raw CSV data EXACTLY as
-- received. Every source column is TEXT so nothing is lost or corrupted on the
-- way in (see data_profiling_report findings P1/P2: GTIN14 / GLN / SSCC18 lose
-- leading zeros or precision if read as numbers). Type casting, zero-padding and
-- all validation happen later, in the transform step, before the DuckDB mart.
--
-- One ods table per Phase 1 source:
--   01_master_data.csv        -> ods.master_data     (63 rows)
--   05_pharmacy_sales_data.csv-> ods.pharmacy_sales  (500,000 rows)
--   06_hospital_demand_data.csv-> ods.hospital_demand (27,216 rows)
--
-- Loads APPEND (never truncate), so refresh history is kept. Three ETL audit
-- columns are added to every row:
--   etl_batch_id  which pipeline run loaded the row  (e.g. 'sdi_20261111T0930')
--   source_file   the file it came from             ('05_pharmacy_sales_data.csv')
--   loaded_at     when it landed                     (defaults to now())
--
-- Ubuntu (WSL):
--   PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -f ~/pipeline/sql/postgres/02_ods_tables.sql
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS ods;

-- ---------------------------------------------------------------------
-- ods.master_data  <- 01_master_data.csv   (34 source columns)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ods.master_data (
    "MedicineID"                    TEXT,
    "InternalSKU"                   TEXT,
    "GTIN14"                        TEXT,
    "GenericName"                   TEXT,
    "FictionalBrandName"            TEXT,
    "DiseaseCategory"               TEXT,
    "ICD10Category"                 TEXT,
    "ATCCode"                       TEXT,
    "TherapeuticClass"              TEXT,
    "DosageForm"                    TEXT,
    "Strength"                      TEXT,
    "RouteOfAdministration"         TEXT,
    "PackSize"                      TEXT,
    "BaseUnitOfMeasure"             TEXT,
    "PrescriptionClass"             TEXT,
    "ControlledMedicineFlag"        TEXT,
    "ColdChainFlag"                 TEXT,
    "StorageMinTempC"               TEXT,
    "StorageMaxTempC"               TEXT,
    "MaxHumidityPct"                TEXT,
    "ShelfLifeMonths"               TEXT,
    "MinimumRemainingShelfLifeDays" TEXT,
    "PrimarySupplierID"             TEXT,
    "PrimaryPlantID"                TEXT,
    "ManufacturingLeadTimeDays"     TEXT,
    "StandardBatchSizePacks"        TEXT,
    "SafetyStockDays"               TEXT,
    "ReorderReviewCycleDays"        TEXT,
    "UnitManufacturingCostUSD"      TEXT,
    "WholesalePriceUSD"             TEXT,
    "RecommendedRetailPriceUSD"     TEXT,
    "ProductStatus"                 TEXT,
    "EffectiveFromDate"             TEXT,
    "SourceSystem"                  TEXT,
    -- ETL audit columns (not from the source file)
    etl_batch_id                    TEXT,
    source_file                     TEXT,
    loaded_at                       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- ods.pharmacy_sales  <- 05_pharmacy_sales_data.csv   (45 source columns)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ods.pharmacy_sales (
    "SalesTransactionID"            TEXT,
    "SalesDate"                     TEXT,
    "SalesTimestampUTC"             TEXT,
    "SalesChannel"                  TEXT,
    "PharmacyID"                    TEXT,
    "PharmacyGLN"                   TEXT,
    "PharmacyName"                  TEXT,
    "PharmacyType"                  TEXT,
    "HospitalID"                    TEXT,
    "PharmacyCity"                  TEXT,
    "PharmacyState"                 TEXT,
    "CountryCode"                   TEXT,
    "PharmacyOrderID"               TEXT,
    "PharmacyDeliveryID"            TEXT,
    "PharmacyDeliveryDate"          TEXT,
    "DeliveryQuantityPacks"         TEXT,
    "DeliveryOTIFFlag"              TEXT,
    "WarehouseLotID"                TEXT,
    "SourceWarehouseID"             TEXT,
    "ProductionBatchID"             TEXT,
    "MedicineID"                    TEXT,
    "GTIN14"                        TEXT,
    "DiseaseCategory"               TEXT,
    "GenericName"                   TEXT,
    "BatchExpiryDate"               TEXT,
    "DaysToExpiryAtSale"            TEXT,
    "QuantitySoldPacks"             TEXT,
    "UnitRetailPriceUSD"            TEXT,
    "GrossSalesAmountUSD"           TEXT,
    "DiscountAmountUSD"             TEXT,
    "NetSalesAmountUSD"             TEXT,
    "SalesTaxUSD"                   TEXT,
    "CostOfGoodsSoldUSD"            TEXT,
    "GrossMarginUSD"                TEXT,
    "PromotionCode"                 TEXT,
    "PrescriptionRequiredFlag"      TEXT,
    "PrescriptionID"                TEXT,
    "CustomerSegment"               TEXT,
    "PayerType"                     TEXT,
    "PaymentMethod"                 TEXT,
    "EcommerceDeliveryStatus"       TEXT,
    "ReturnFlag"                    TEXT,
    "ReturnedQuantityPacks"         TEXT,
    "SaleStatus"                    TEXT,
    "SourceSystem"                  TEXT,
    -- ETL audit columns (not from the source file)
    etl_batch_id                    TEXT,
    source_file                     TEXT,
    loaded_at                       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- ods.hospital_demand  <- 06_hospital_demand_data.csv   (41 source columns)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ods.hospital_demand (
    "HospitalDemandRecordID"        TEXT,
    "DemandMonth"                   TEXT,
    "HospitalID"                    TEXT,
    "HospitalGLN"                   TEXT,
    "HospitalName"                  TEXT,
    "HospitalType"                  TEXT,
    "HospitalPharmacyID"            TEXT,
    "City"                          TEXT,
    "State"                         TEXT,
    "CountryCode"                   TEXT,
    "LicensedBeds"                  TEXT,
    "ICUBeds"                       TEXT,
    "AverageOccupancyRatePct"       TEXT,
    "TraumaLevel"                   TEXT,
    "CatchmentPopulation"           TEXT,
    "MedicineID"                    TEXT,
    "GTIN14"                        TEXT,
    "GenericName"                   TEXT,
    "DiseaseCategory"               TEXT,
    "ICD10Category"                 TEXT,
    "EstimatedDiseaseCases"         TEXT,
    "DiseaseRelatedAdmissions"      TEXT,
    "OutpatientEncounters"          TEXT,
    "ForecastDemandPacks"           TEXT,
    "RequestedQuantityPacks"        TEXT,
    "ApprovedQuantityPacks"         TEXT,
    "ReceivedQuantityPacks"         TEXT,
    "EmergencyRequestQuantityPacks" TEXT,
    "OpeningStockPacks"             TEXT,
    "DispensedQuantityPacks"        TEXT,
    "ConsumedQuantityPacks"         TEXT,
    "WastageQuantityPacks"          TEXT,
    "ClosingStockPacks"             TEXT,
    "UnfulfilledDemandPacks"        TEXT,
    "StockoutDays"                  TEXT,
    "ServiceLevelPct"               TEXT,
    "MedicationRequestStatus"       TEXT,
    "FormularyStatus"               TEXT,
    "AverageLeadTimeDays"           TEXT,
    "DemandTrendIndex"              TEXT,
    "SourceSystem"                  TEXT,
    -- ETL audit columns (not from the source file)
    etl_batch_id                    TEXT,
    source_file                     TEXT,
    loaded_at                       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Helpful for "what did refresh N add?" queries on the storage dashboard.
CREATE INDEX IF NOT EXISTS ix_ods_master_data_batch    ON ods.master_data    (etl_batch_id);
CREATE INDEX IF NOT EXISTS ix_ods_pharmacy_sales_batch ON ods.pharmacy_sales (etl_batch_id);
CREATE INDEX IF NOT EXISTS ix_ods_hospital_demand_batch ON ods.hospital_demand (etl_batch_id);

-- ---------------------------------------------------------------------
-- Dedup support for the ingestion layer.
-- meta.batch_log (defined in 01_meta_tables.sql) gets one extra, additive
-- column so a file that was already loaded successfully is never loaded twice.
-- ADD COLUMN IF NOT EXISTS keeps this idempotent and does not touch the
-- existing meta schema. ingest_api.py checks this column before every load.
-- ---------------------------------------------------------------------
ALTER TABLE meta.batch_log ADD COLUMN IF NOT EXISTS file_hash TEXT;
CREATE INDEX IF NOT EXISTS ix_batch_log_file_hash ON meta.batch_log (file_hash);
