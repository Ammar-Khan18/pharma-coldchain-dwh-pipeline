-- =====================================================================
-- sdi_00_drop_legacy.sql  —  Phase 1 mart, STEP 0: drop the pre-Excel schema
-- WBS 3.1 (Excel alignment). Removes every object from the OLD lowercase
-- snake_case mart so sdi_01_create_schema.sql can rebuild the PascalCase model
-- described in docs/excel_alignment_plan.md without name/column collisions.
--
-- Runs INSIDE the DuckDB mart (schema sdi). Safe to run many times: every drop
-- is IF EXISTS. This file ONLY drops legacy objects; it never touches the new
-- PascalCase tables (DimDate, DimMedicine, …) or the seed_* lookup tables, so
-- running it after a rebuild is a no-op.
--
-- NOTE: this is destructive for the old mart. The facts are rebuilt from the ODS
-- by the transform, and the ODS (Postgres) is untouched, so no source data is lost.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS sdi;

-- Old facts ------------------------------------------------------------------
DROP TABLE IF EXISTS sdi.fact_sales;
DROP TABLE IF EXISTS sdi.fact_hospital_demand;

-- Old aggregates (query layer) ----------------------------------------------
DROP TABLE IF EXISTS sdi.agg_sales_month_channel;
DROP TABLE IF EXISTS sdi.agg_demand_month_hospital;
DROP TABLE IF EXISTS sdi.agg_sales_medicine_month;

-- Old dimensions -------------------------------------------------------------
DROP TABLE IF EXISTS sdi.dim_date;
DROP TABLE IF EXISTS sdi.dim_medicine;
DROP TABLE IF EXISTS sdi.dim_pharmacy;
DROP TABLE IF EXISTS sdi.dim_hospital;
DROP TABLE IF EXISTS sdi.dim_channel;         -- removed in the Excel model
DROP TABLE IF EXISTS sdi.dim_sales_profile;   -- junk dim removed
DROP TABLE IF EXISTS sdi.dim_demand_status;   -- junk dim removed

-- Old surrogate-key sequences ------------------------------------------------
DROP SEQUENCE IF EXISTS sdi.seq_medicine_key;
DROP SEQUENCE IF EXISTS sdi.seq_pharmacy_key;
DROP SEQUENCE IF EXISTS sdi.seq_hospital_key;
DROP SEQUENCE IF EXISTS sdi.seq_sales_profile_key;
DROP SEQUENCE IF EXISTS sdi.seq_demand_status_key;
