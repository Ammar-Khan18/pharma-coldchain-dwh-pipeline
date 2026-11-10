-- =====================================================================
-- Phase 1: Sales & Demand Intelligence (SDI) data mart  —  DuckDB
-- File: sql/mart/sdi_01_create_schema.sql          (WBS 3.1 / 3.3)
--
-- Safe to run many times: everything is IF NOT EXISTS / ON CONFLICT.
-- The mart is never dropped; refreshes only append/update (history kept).
--
-- Conformed dimensions (shared with Phase 2/3 and the final constellation):
--   dim_date, dim_medicine
-- Phase-1 dimensions:
--   dim_pharmacy, dim_hospital, dim_channel,
--   dim_sales_profile (junk), dim_demand_status (junk)
-- Facts:
--   fact_sales            transaction fact      grain = 1 sales transaction
--   fact_hospital_demand  periodic snapshot     grain = 1 hospital x medicine x month
--
-- Every dimension has an "Unknown / Not applicable" member with key -1,
-- so fact rows never need NULL foreign keys.
-- FKs are not declared (normal in DWHs, and DuckDB FKs slow loads);
-- the transform step guarantees them and the validation step checks them.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS sdi;

-- ---------------------------------------------------------------------
-- dim_date  (conformed, role-playing)
-- Used as: sale date, pharmacy delivery date, batch expiry date (fact_sales)
--          and demand month (fact_hospital_demand, first day of month).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sdi.dim_date (
    date_key          INTEGER PRIMARY KEY,      -- yyyymmdd, e.g. 20240315; -1 = unknown
    full_date         DATE,
    day_of_month      SMALLINT,
    day_of_week_num   SMALLINT,                 -- 1 = Monday ... 7 = Sunday
    day_name          VARCHAR,
    is_weekend        BOOLEAN,
    iso_week          SMALLINT,
    month_num         SMALLINT,
    month_name        VARCHAR,
    month_short       VARCHAR,
    year_month        VARCHAR,                  -- '2024-03'
    month_start_date  DATE,
    quarter_num       SMALLINT,
    year_quarter      VARCHAR,                  -- '2024-Q1'
    year_num          SMALLINT
);

INSERT INTO sdi.dim_date
SELECT CAST(strftime(d, '%Y%m%d') AS INTEGER),
       d::DATE, day(d), isodow(d), dayname(d), isodow(d) >= 6, weekofyear(d),
       month(d), monthname(d), left(monthname(d), 3), strftime(d, '%Y-%m'),
       date_trunc('month', d)::DATE, quarter(d),
       year(d) || '-Q' || quarter(d), year(d)
FROM generate_series(DATE '2022-01-01', DATE '2029-12-31', INTERVAL 1 DAY) AS g(d)
ON CONFLICT DO NOTHING;

INSERT INTO sdi.dim_date (date_key, day_name, month_name, year_month, year_quarter)
VALUES (-1, 'Unknown', 'Unknown', 'Unknown', 'Unknown')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- dim_medicine  (conformed, SCD Type 2)
-- Type 2 (new row, history kept): prices/costs, ProductStatus,
--   PrescriptionClass, ColdChainFlag, storage limits.
-- Type 1 (overwrite): names/descriptive text.
-- Facts store the medicine_key that was current on the event date.
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sdi.seq_medicine_key START 1;

CREATE TABLE IF NOT EXISTS sdi.dim_medicine (
    medicine_key                INTEGER PRIMARY KEY DEFAULT nextval('sdi.seq_medicine_key'),
    medicine_id                 VARCHAR NOT NULL,       -- natural key, MED001
    internal_sku                VARCHAR,
    gtin14                      VARCHAR,                -- TEXT, zero-padded to 14 digits
    generic_name                VARCHAR,
    brand_name                  VARCHAR,
    disease_category            VARCHAR,
    icd10_category              VARCHAR,
    atc_code                    VARCHAR,
    therapeutic_class           VARCHAR,
    dosage_form                 VARCHAR,
    strength                    VARCHAR,
    route_of_administration     VARCHAR,
    pack_size                   INTEGER,
    base_unit_of_measure        VARCHAR,
    prescription_class          VARCHAR,
    controlled_medicine_flag    VARCHAR,
    cold_chain_flag             VARCHAR,
    storage_min_temp_c          INTEGER,
    storage_max_temp_c          INTEGER,
    max_humidity_pct            INTEGER,
    shelf_life_months           INTEGER,
    min_remaining_shelf_life_days INTEGER,
    primary_supplier_id         VARCHAR,
    primary_plant_id            VARCHAR,
    manufacturing_lead_time_days INTEGER,
    standard_batch_size_packs   INTEGER,
    safety_stock_days           INTEGER,
    reorder_review_cycle_days   INTEGER,
    unit_manufacturing_cost_usd DECIMAL(12,4),
    wholesale_price_usd         DECIMAL(12,4),
    recommended_retail_price_usd DECIMAL(12,4),
    product_status              VARCHAR,
    -- SCD2 housekeeping
    scd2_hash                   VARCHAR,                -- md5 of the Type-2 columns
    valid_from                  DATE NOT NULL,
    valid_to                    DATE NOT NULL DEFAULT DATE '9999-12-31',
    is_current                  BOOLEAN NOT NULL DEFAULT TRUE,
    etl_batch_id                VARCHAR,
    loaded_at                   TIMESTAMP DEFAULT current_timestamp
);

INSERT INTO sdi.dim_medicine (medicine_key, medicine_id, generic_name, brand_name,
       disease_category, therapeutic_class, valid_from)
VALUES (-1, 'UNKNOWN', 'Unknown', 'Unknown', 'Unknown', 'Unknown', DATE '1900-01-01')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- dim_pharmacy  (SCD Type 1) — built from distinct pharmacies in 05
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sdi.seq_pharmacy_key START 1;

CREATE TABLE IF NOT EXISTS sdi.dim_pharmacy (
    pharmacy_key        INTEGER PRIMARY KEY DEFAULT nextval('sdi.seq_pharmacy_key'),
    pharmacy_id         VARCHAR NOT NULL UNIQUE,
    pharmacy_gln        VARCHAR,
    pharmacy_name       VARCHAR,
    pharmacy_type       VARCHAR,          -- Chain / Independent / Hospital Pharmacy
    linked_hospital_id  VARCHAR,          -- filled for hospital pharmacies only
    city                VARCHAR,
    state               VARCHAR,
    country_code        VARCHAR,
    etl_batch_id        VARCHAR,
    updated_at          TIMESTAMP DEFAULT current_timestamp
);

INSERT INTO sdi.dim_pharmacy (pharmacy_key, pharmacy_id, pharmacy_name, pharmacy_type, city, state)
VALUES (-1, 'UNKNOWN', 'Unknown', 'Unknown', 'Unknown', 'Unknown')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- dim_hospital  (SCD Type 1) — built from distinct hospitals in 06
-- key -1 = "Not a hospital sale" (used by retail / e-commerce rows in fact_sales)
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sdi.seq_hospital_key START 1;

CREATE TABLE IF NOT EXISTS sdi.dim_hospital (
    hospital_key            INTEGER PRIMARY KEY DEFAULT nextval('sdi.seq_hospital_key'),
    hospital_id             VARCHAR NOT NULL UNIQUE,
    hospital_gln            VARCHAR,
    hospital_name           VARCHAR,
    hospital_type           VARCHAR,
    hospital_pharmacy_id    VARCHAR,
    city                    VARCHAR,
    state                   VARCHAR,
    country_code            VARCHAR,
    licensed_beds           INTEGER,
    icu_beds                INTEGER,
    avg_occupancy_rate_pct  INTEGER,
    trauma_level            VARCHAR,       -- empty in source -> 'Not designated'
    catchment_population    INTEGER,
    bed_size_band           VARCHAR,       -- derived: Small <400, Medium 400-699, Large 700+
    etl_batch_id            VARCHAR,
    updated_at              TIMESTAMP DEFAULT current_timestamp
);

INSERT INTO sdi.dim_hospital (hospital_key, hospital_id, hospital_name, hospital_type,
       trauma_level, bed_size_band, city, state)
VALUES (-1, 'N/A', 'Not a hospital sale', 'N/A', 'N/A', 'N/A', 'N/A', 'N/A')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- dim_channel  (static, 3 business channels from the spec)
-- Derivation (confirm with check C1):
--   SalesChannel = 'Ecommerce'                      -> ECOM
--   else PharmacyType = 'Hospital Pharmacy'         -> HOSPITAL
--   else                                            -> RETAIL
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sdi.dim_channel (
    channel_key     INTEGER PRIMARY KEY,
    channel_code    VARCHAR NOT NULL UNIQUE,
    channel_name    VARCHAR,
    channel_group   VARCHAR            -- Physical / Online
);

INSERT INTO sdi.dim_channel VALUES
    (-1, 'UNKNOWN',  'Unknown',    'Unknown'),
    ( 1, 'RETAIL',   'Retail',     'Physical'),
    ( 2, 'HOSPITAL', 'Hospital',   'Physical'),
    ( 3, 'ECOM',     'E-commerce', 'Online')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- dim_sales_profile  (JUNK dimension)
-- Collects low-cardinality flags/codes from 05 so fact_sales stays narrow.
-- One row per combination actually seen; new combos are added on refresh.
-- Empty PromotionCode is stored as 'NONE'.
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sdi.seq_sales_profile_key START 1;

CREATE TABLE IF NOT EXISTS sdi.dim_sales_profile (
    sales_profile_key           INTEGER PRIMARY KEY DEFAULT nextval('sdi.seq_sales_profile_key'),
    prescription_required_flag  VARCHAR NOT NULL,
    customer_segment            VARCHAR NOT NULL,
    payer_type                  VARCHAR NOT NULL,
    payment_method              VARCHAR NOT NULL,
    promotion_code              VARCHAR NOT NULL,
    has_promotion               BOOLEAN,
    ecommerce_delivery_status   VARCHAR NOT NULL,
    return_flag                 VARCHAR NOT NULL,
    sale_status                 VARCHAR NOT NULL,
    delivery_otif_flag          VARCHAR NOT NULL,
    UNIQUE (prescription_required_flag, customer_segment, payer_type, payment_method,
            promotion_code, ecommerce_delivery_status, return_flag, sale_status,
            delivery_otif_flag)
);

INSERT INTO sdi.dim_sales_profile VALUES
    (-1, '?', 'Unknown', 'Unknown', 'Unknown', 'Unknown', FALSE, 'Unknown', '?', 'Unknown', '?')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- dim_demand_status  (JUNK dimension for 06: 2 x 3 = 6 combos)
-- ---------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS sdi.seq_demand_status_key START 1;

CREATE TABLE IF NOT EXISTS sdi.dim_demand_status (
    demand_status_key           INTEGER PRIMARY KEY DEFAULT nextval('sdi.seq_demand_status_key'),
    medication_request_status   VARCHAR NOT NULL,
    formulary_status            VARCHAR NOT NULL,
    UNIQUE (medication_request_status, formulary_status)
);

INSERT INTO sdi.dim_demand_status VALUES (-1, 'Unknown', 'Unknown')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- fact_sales  — TRANSACTION fact
-- Grain: one row per pharmacy sales transaction (one row of 05).
-- Role-playing dim_date: sale_date_key, pharmacy_delivery_date_key, batch_expiry_date_key
-- Degenerate dims: transaction / order / delivery / prescription IDs, batch & lot IDs
--   (batch/lot/warehouse become real dims in Phase 2 via dim_batch / dim_warehouse).
-- Additive: quantities and USD amounts.  Non-additive: unit price, days_to_expiry.
-- NOT stored: DeliveryQuantityPacks (it belongs to the delivery, repeats on every sale
--   of that delivery, and would be double-counted if summed).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sdi.fact_sales (
    sales_transaction_id        VARCHAR PRIMARY KEY,    -- degenerate dim; also stops double loads
    sale_date_key               INTEGER NOT NULL,
    pharmacy_delivery_date_key  INTEGER NOT NULL,
    batch_expiry_date_key       INTEGER NOT NULL,
    medicine_key                INTEGER NOT NULL,
    pharmacy_key                INTEGER NOT NULL,
    hospital_key                INTEGER NOT NULL,       -- -1 for non-hospital sales
    channel_key                 INTEGER NOT NULL,
    sales_profile_key           INTEGER NOT NULL,
    -- degenerate / lineage
    sales_timestamp_utc         TIMESTAMP,
    pharmacy_order_id           VARCHAR,
    pharmacy_delivery_id        VARCHAR,
    prescription_id             VARCHAR,
    production_batch_id         VARCHAR,
    warehouse_lot_id            VARCHAR,
    source_warehouse_id         VARCHAR,
    source_system               VARCHAR,
    -- measures
    quantity_sold_packs         INTEGER,
    returned_quantity_packs     INTEGER,
    net_quantity_packs          INTEGER,                -- sold - returned
    unit_retail_price_usd       DECIMAL(12,2),          -- non-additive
    gross_sales_usd             DECIMAL(12,2),
    discount_usd                DECIMAL(12,2),
    net_sales_usd               DECIMAL(12,2),
    sales_tax_usd               DECIMAL(12,2),
    cogs_usd                    DECIMAL(12,2),
    gross_margin_usd            DECIMAL(12,2),
    days_to_expiry_at_sale      INTEGER,                -- non-additive
    -- data quality + audit
    dq_warning_count            SMALLINT DEFAULT 0,     -- # of 'warn' rules this row broke
    etl_batch_id                VARCHAR,
    loaded_at                   TIMESTAMP DEFAULT current_timestamp
);

-- ---------------------------------------------------------------------
-- fact_hospital_demand  — PERIODIC SNAPSHOT fact (monthly)
-- Grain: one row per hospital x medicine x month.
-- Fully additive: forecast/requested/approved/received/emergency/dispensed/
--   consumed/wastage/unfulfilled quantities.
-- Semi-additive: opening_stock, closing_stock (sum across hospitals or medicines,
--   never across months; use the last month instead).
-- Non-additive: service_level_pct, avg_lead_time_days, demand_trend_index
--   (recompute from sums or use AVG).
-- Disease-level context (cases/admissions/encounters) — see check C13 before summing.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sdi.fact_hospital_demand (
    hospital_demand_record_id   VARCHAR PRIMARY KEY,    -- degenerate dim
    month_date_key              INTEGER NOT NULL,       -- dim_date, 1st of the month
    hospital_key                INTEGER NOT NULL,
    medicine_key                INTEGER NOT NULL,
    demand_status_key           INTEGER NOT NULL,
    -- context measures
    estimated_disease_cases     INTEGER,
    disease_related_admissions  INTEGER,
    outpatient_encounters       INTEGER,
    -- flow measures (additive)
    forecast_demand_packs       INTEGER,
    requested_qty_packs         INTEGER,
    approved_qty_packs          INTEGER,
    received_qty_packs          INTEGER,
    emergency_request_qty_packs INTEGER,
    dispensed_qty_packs         INTEGER,
    consumed_qty_packs          INTEGER,
    wastage_qty_packs           INTEGER,
    unfulfilled_demand_packs    INTEGER,
    stockout_days               INTEGER,
    -- level measures (semi-additive)
    opening_stock_packs         INTEGER,
    closing_stock_packs         INTEGER,
    -- ratios (non-additive)
    service_level_pct           DECIMAL(6,2),
    avg_lead_time_days          INTEGER,
    demand_trend_index          DECIMAL(8,3),
    forecast_error_packs        INTEGER,                -- consumed - forecast (derived)
    -- data quality + audit
    dq_warning_count            SMALLINT DEFAULT 0,
    etl_batch_id                VARCHAR,
    loaded_at                   TIMESTAMP DEFAULT current_timestamp
);
