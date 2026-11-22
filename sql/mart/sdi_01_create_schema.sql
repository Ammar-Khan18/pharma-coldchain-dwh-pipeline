-- =====================================================================
-- Phase 1: Sales & Demand Intelligence (SDI) data mart  —  DuckDB
-- File: sql/mart/sdi_01_create_schema.sql          (WBS 3.1 / 3.3)
--
-- PascalCase model, aligned exactly to the graded design workbook
-- (docs/phase1_sdi_design.xlsx); see docs/excel_alignment_plan.md.
-- Run sql/mart/sdi_00_drop_legacy.sql first when migrating from the old
-- lowercase schema.
--
-- Conventions kept from the previous schema:
--   * surrogate keys from DuckDB sequences, DEFAULT nextval(...)
--   * a -1 "Unknown" member in EVERY dimension, so fact FKs are never NULL
--   * foreign keys are NOT declared (normal in DWHs; DuckDB FKs slow loads) —
--     the transform guarantees them and sdi_40_tests checks them
--   * both facts carry etl_batch_id + loaded_at (audit, lowercase)
--
-- Identifiers are DOUBLE-QUOTED so the exact PascalCase survives into Postgres
-- (publish_mart.py quotes column names, and Postgres is case-sensitive there).
--
-- Safe to run many times: schema/tables are IF NOT EXISTS, seeds + dim_date are
-- CREATE OR REPLACE / ON CONFLICT DO NOTHING.
--
-- Dimensions (Excel): DimDate, DimMedicine (SCD2 on PresClass + ProductStatus),
--   DimLocation (City+State, conformed), DimPharmacy (SCD1, grain = PharmacyID +
--   SalesChannel), DimHospital (SCD1).
-- Facts (Excel): FactPharmacySales (1 row per SalesTransactionID),
--   FactHospitalDemand (hospital x medicine x month).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS sdi;

-- ---------------------------------------------------------------------
-- Seed / lookup tables (sdi.seed_*)  — loaded from sql/seeds/*.csv
-- `seed_dir` defaults to the repo-relative path; the transform DAG may
-- `SET VARIABLE seed_dir='<abs path>'` before running this file to override it.
-- ---------------------------------------------------------------------
SET VARIABLE seed_dir = coalesce(getvariable('seed_dir'), 'sql/seeds');

CREATE OR REPLACE TABLE sdi.seed_dosage_form_abbrev AS
    SELECT CAST(dosage_form AS VARCHAR) AS dosage_form,
           CAST(abbrev AS VARCHAR)      AS abbrev
    FROM read_csv(getvariable('seed_dir') || '/dosage_form_abbrev.csv', header = true);

CREATE OR REPLACE TABLE sdi.seed_pharmacy_type_abbrev AS
    SELECT CAST(pharmacy_type AS VARCHAR) AS pharmacy_type,
           CAST(abbrev AS VARCHAR)        AS abbrev
    FROM read_csv(getvariable('seed_dir') || '/pharmacy_type_abbrev.csv', header = true);

CREATE OR REPLACE TABLE sdi.seed_pharmacy_short_names AS
    SELECT CAST(pharmacy_id AS VARCHAR)   AS pharmacy_id,
           CAST(pharmacy_name AS VARCHAR) AS pharmacy_name
    FROM read_csv(getvariable('seed_dir') || '/pharmacy_short_names.csv', header = true);

-- ---------------------------------------------------------------------
-- DimDate  (conformed; one role — the sale date / demand month)
-- DateKey = yyyymmdd. Member -1 = Unknown. Rows are filled by the transform
-- (sdi_21_dim_date.sql), not here.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sdi."DimDate" (
    "DateKey"   INTEGER PRIMARY KEY,     -- yyyymmdd; -1 = unknown
    "FullDate"  DATE,
    "Day"       INTEGER,
    "DayName"   VARCHAR,                 -- 'Mon' .. 'Sun'
    "Month"     INTEGER,
    "MonthName" VARCHAR,                 -- 'Jan' .. 'Dec'
    "Quarter"   VARCHAR,                 -- 'Q1' .. 'Q4'
    "Year"      INTEGER
);

-- DimDate is filled by the transform (sql/mart/sdi_21_dim_date.sql), which runs
-- from 2023-01-01 to 31 Dec of the latest SalesDate/DemandMonth year and adds only
-- missing days. This schema file seeds ONLY the -1 Unknown member.
INSERT INTO sdi."DimDate" ("DateKey", "DayName", "MonthName", "Quarter")
VALUES (-1, 'Unknown', 'Unknown', 'Unknown')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DimMedicine  (SCD Type 2 on PresClass + ProductStatus; Type 1 otherwise)
-- Natural/business key = InternalSKU. Price/cost are NOT tracked here — they
-- are copied per sale onto FactPharmacySales (MfgCost / MRP / ListTradePrice).
-- Facts store the MedicineKey whose [EffectiveFrom, EffectiveTo] covers the event date.
-- PackSize and ShelfLife are banded VARCHARs ('Large'/'Small', 'Short.SL'/'Long.SL').
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sdi.seq_dim_medicine START 1;

CREATE TABLE IF NOT EXISTS sdi."DimMedicine" (
    "MedicineKey"       INTEGER PRIMARY KEY DEFAULT nextval('sdi.seq_dim_medicine'),
    "InternalSKU"       VARCHAR,          -- natural key
    "MedicineID"        VARCHAR,
    "GTIN14"            VARCHAR,           -- 14 chars, zero-padded
    "MedName"           VARCHAR,
    "TherapeuticClass"  VARCHAR,
    "DiseaseCategory"   VARCHAR,
    "ICD10Category"     VARCHAR,
    "DosageStrength"    VARCHAR,
    "Route"             VARCHAR,
    "PackSize"          VARCHAR,           -- 'Large' / 'Small'
    "BaseUOM"           VARCHAR,
    "PresClass"         VARCHAR,           -- SCD2 trigger
    "ColdChainFlag"     VARCHAR(1),        -- 'Y' / 'N'
    "ControlledMedFlag" VARCHAR(1),        -- 'Y' / 'N'
    "ShelfLife"         VARCHAR,           -- 'Short.SL' / 'Long.SL'
    "ProductStatus"     VARCHAR,           -- SCD2 trigger
    "EffectiveFrom"     DATE,
    "EffectiveTo"       DATE DEFAULT DATE '9999-12-31',
    "IsCurrent"         VARCHAR(1) DEFAULT 'Y'   -- 'Y' / 'N'
);

INSERT INTO sdi."DimMedicine"
    ("MedicineKey", "InternalSKU", "MedicineID", "GTIN14", "MedName", "TherapeuticClass",
     "DiseaseCategory", "ICD10Category", "DosageStrength", "Route", "PackSize", "BaseUOM",
     "PresClass", "ColdChainFlag", "ControlledMedFlag", "ShelfLife", "ProductStatus",
     "EffectiveFrom", "EffectiveTo", "IsCurrent")
VALUES (-1, 'UNKNOWN', 'UNKNOWN', 'UNKNOWN', 'Unknown', 'Unknown',
        'Unknown', 'Unknown', 'Unknown', 'Unknown', 'N/A', 'N/A',
        'Unknown', 'N', 'N', 'N/A', 'Unknown',
        DATE '1900-01-01', DATE '9999-12-31', 'Y')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DimLocation  (conformed; natural key = City + State) — shared by pharmacy & hospital
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sdi.seq_dim_location START 1;

CREATE TABLE IF NOT EXISTS sdi."DimLocation" (
    "LocationKey" INTEGER PRIMARY KEY DEFAULT nextval('sdi.seq_dim_location'),
    "City"        VARCHAR,
    "State"       VARCHAR,
    "Country"     VARCHAR,
    UNIQUE ("City", "State")
);

INSERT INTO sdi."DimLocation" ("LocationKey", "City", "State", "Country")
VALUES (-1, 'Unknown', 'Unknown', 'Unknown')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DimPharmacy  (SCD Type 1)  — grain = one row per (PharmacyID, SalesChannel)
-- SalesChannel stays here; FactPharmacySales.PharmacyKey is looked up by
-- PharmacyID AND SalesChannel (48 pharmacies sell through both channels).
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sdi.seq_dim_pharmacy START 1;

CREATE TABLE IF NOT EXISTS sdi."DimPharmacy" (
    "PharmacyKey"  INTEGER PRIMARY KEY DEFAULT nextval('sdi.seq_dim_pharmacy'),
    "PharmacyID"   VARCHAR,
    "PharmacyGLN"  VARCHAR,              -- 13 chars
    "PharmacyName" VARCHAR,
    "PharmacyType" VARCHAR,
    "SalesChannel" VARCHAR,              -- 'Physical Pharmacy' / 'Ecommerce'
    "LocationKey"  INTEGER,
    UNIQUE ("PharmacyID", "SalesChannel")
);

INSERT INTO sdi."DimPharmacy"
    ("PharmacyKey", "PharmacyID", "PharmacyGLN", "PharmacyName", "PharmacyType",
     "SalesChannel", "LocationKey")
VALUES (-1, 'N/A', 'N/A', 'Unknown', 'N/A', 'N/A', -1)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- DimHospital  (SCD Type 1)
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sdi.seq_dim_hospital START 1;

CREATE TABLE IF NOT EXISTS sdi."DimHospital" (
    "HospitalKey"  INTEGER PRIMARY KEY DEFAULT nextval('sdi.seq_dim_hospital'),
    "HospitalID"   VARCHAR,
    "HospitalGLN"  VARCHAR,              -- 13 chars
    "HospitalName" VARCHAR,
    "HospitalType" VARCHAR,
    "LocationKey"  INTEGER,
    UNIQUE ("HospitalID")
);

INSERT INTO sdi."DimHospital"
    ("HospitalKey", "HospitalID", "HospitalGLN", "HospitalName", "HospitalType", "LocationKey")
VALUES (-1, 'N/A', 'N/A', 'Not a hospital sale', 'N/A', -1)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- FactPharmacySales  — TRANSACTION fact
-- Grain: one row per SalesTransactionID (one row of 05).
-- SalesTransactionID + CustomerSegment are degenerate dimensions.
-- MfgCost / MRP / ListTradePrice hold the price/cost in effect at sale time
-- (price history lives in the fact, since DimMedicine is Type 1 for prices).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sdi."FactPharmacySales" (
    "DateKey"             INTEGER NOT NULL,
    "MedicineKey"         INTEGER NOT NULL,
    "PharmacyKey"         INTEGER NOT NULL,
    "SalesTransactionID"  VARCHAR PRIMARY KEY,   -- degenerate; also stops double loads
    "CustomerSegment"     VARCHAR,               -- degenerate
    "QuantitySold"        INTEGER,
    "ReturnedQty"         INTEGER,
    "GrossSales"          DECIMAL(12,2),
    "Discount"            DECIMAL(12,2),
    "NetSales"            DECIMAL(12,2),
    "SalesTax"            DECIMAL(12,2),
    "COGS"                DECIMAL(12,2),
    "GrossMargin"         DECIMAL(12,2),
    "DaysToExpiryAtSale"  INTEGER,
    "MfgCost"             DECIMAL(12,2),
    "MRP"                 DECIMAL(12,2),
    "ListTradePrice"      DECIMAL(12,2),
    etl_batch_id          VARCHAR,
    loaded_at             TIMESTAMP DEFAULT current_timestamp
);

-- ---------------------------------------------------------------------
-- FactHospitalDemand  — PERIODIC SNAPSHOT fact (monthly)
-- Grain: one row per hospital x medicine x month.
-- Occupancy_PCT is the Excel's "Occupancy.PCT" (a dot is illegal in a column name).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sdi."FactHospitalDemand" (
    "DateKey"                   INTEGER NOT NULL,
    "HospitalKey"               INTEGER NOT NULL,
    "MedicineKey"               INTEGER NOT NULL,
    "Occupancy_PCT"             DECIMAL(5,2),
    "ICUBeds"                   INTEGER,
    "LicensedBeds"              INTEGER,
    "EstimatedDiseaseCases"     INTEGER,
    "DiseaseRelatedAdmissions"  INTEGER,
    "OutpatientEncounters"      INTEGER,
    "ForecastDemand"            INTEGER,
    "RequestedQty"              INTEGER,
    "ApprovedQty"               INTEGER,
    "EmergencyRequestQty"       INTEGER,
    "OpeningStock"              INTEGER,
    "DispensedQty"              INTEGER,
    "ConsumedQty"               INTEGER,
    "WastageQty"                INTEGER,
    "ClosingStock"              INTEGER,
    "UnfulfilledDemand"         INTEGER,
    "StockoutDays"              INTEGER,
    "DemandTrendIndex"          DECIMAL(6,3),
    etl_batch_id                VARCHAR,
    loaded_at                   TIMESTAMP DEFAULT current_timestamp
);
