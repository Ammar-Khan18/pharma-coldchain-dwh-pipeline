-- =====================================================================
-- sdi_50_aggregates.sql  —  Phase 1 query layer: indexes + pre-aggregate tables
-- WBS 3.4 / 2.6. Runs in the DuckDB mart (schema sdi). Excel Star.Schema sheet.
--
-- (A) Fact-table indexes (Excel Fact.Table sheet optimisation).
-- (B) Drop the old lowercase agg_* tables.
-- (C) Build the three summary tables the dashboard widgets read:
--       agg_channel_month               (q1_channel_margin)
--       agg_hospital_forecast_month     (q2_hospital_forecast_vs_actual)
--       agg_top_bottom_medicine_state   (q3_top_bottom_by_state)
--     Rebuilt every run (CREATE OR REPLACE) so they always match the facts.
--
-- Percentages are computed as SUM/SUM, never as an average of per-row percentages.
-- =====================================================================

-- (A) Indexes on the fact tables ------------------------------------------
CREATE INDEX IF NOT EXISTS ix_fps_date     ON sdi."FactPharmacySales" ("DateKey");
CREATE INDEX IF NOT EXISTS ix_fps_medicine ON sdi."FactPharmacySales" ("MedicineKey");
CREATE INDEX IF NOT EXISTS ix_fps_pharmacy ON sdi."FactPharmacySales" ("PharmacyKey");
CREATE INDEX IF NOT EXISTS ix_fhd_hospital ON sdi."FactHospitalDemand" ("HospitalKey");
CREATE INDEX IF NOT EXISTS ix_fhd_medicine ON sdi."FactHospitalDemand" ("MedicineKey");
CREATE INDEX IF NOT EXISTS ix_fhd_date     ON sdi."FactHospitalDemand" ("DateKey");

-- (B) Drop the old (pre-Excel) aggregates ---------------------------------
DROP TABLE IF EXISTS sdi.agg_sales_month_channel;
DROP TABLE IF EXISTS sdi.agg_demand_month_hospital;
DROP TABLE IF EXISTS sdi.agg_sales_medicine_month;

-- (C1) agg_channel_month : NetSales / COGS / GrossMargin / margin% by channel-month
CREATE OR REPLACE TABLE sdi.agg_channel_month AS
SELECT d."Year"  AS "Year",
       d."Month" AS "Month",
       p."SalesChannel" AS "SalesChannel",
       sum(f."NetSales")    AS "NetSales",
       sum(f."COGS")        AS "COGS",
       sum(f."GrossMargin") AS "GrossMargin",
       sum(f."GrossMargin") / nullif(sum(f."NetSales"), 0) AS "GrossMarginPct"
FROM sdi."FactPharmacySales" f
JOIN sdi."DimDate"     d ON d."DateKey"     = f."DateKey"
JOIN sdi."DimPharmacy" p ON p."PharmacyKey" = f."PharmacyKey"
GROUP BY d."Year", d."Month", p."SalesChannel"
ORDER BY d."Year", d."Month", p."SalesChannel";

-- (C2) agg_hospital_forecast_month : forecast vs actual by hospital-month.
-- NOTE: ICUBeds, LicensedBeds and Occupancy_PCT repeat on every medicine row of a
-- hospital-month, so they are reduced with MAX / AVG and must NEVER be SUMmed.
CREATE OR REPLACE TABLE sdi.agg_hospital_forecast_month AS
SELECT d."Year"  AS "Year",
       d."Month" AS "Month",
       h."HospitalName" AS "HospitalName",
       h."HospitalType" AS "HospitalType",
       sum(f."ForecastDemand")    AS "ForecastDemand",
       sum(f."ConsumedQty")       AS "ConsumedQty",
       sum(f."UnfulfilledDemand") AS "UnfulfilledDemand",
       sum(f."ConsumedQty") - sum(f."ForecastDemand") AS "ForecastGap",
       (sum(f."ConsumedQty") - sum(f."ForecastDemand")) * 1.0
            / nullif(sum(f."ForecastDemand"), 0) AS "ForecastErrorPct",
       max(f."ICUBeds")        AS "ICUBeds",         -- repeats per medicine -> MAX, never SUM
       max(f."LicensedBeds")   AS "LicensedBeds",    -- repeats per medicine -> MAX, never SUM
       avg(f."Occupancy_PCT")  AS "AvgOccupancyPct"  -- repeats per medicine -> AVG, never SUM
FROM sdi."FactHospitalDemand" f
JOIN sdi."DimDate"     d ON d."DateKey"     = f."DateKey"
JOIN sdi."DimHospital" h ON h."HospitalKey" = f."HospitalKey"
GROUP BY d."Year", d."Month", h."HospitalName", h."HospitalType"
ORDER BY d."Year", d."Month", h."HospitalName";

-- (C3) agg_top_bottom_medicine_state : per State, top 10 and bottom 10 medicines
-- by units sold (via DimPharmacy -> DimLocation). Window functions for the ranks.
CREATE OR REPLACE TABLE sdi.agg_top_bottom_medicine_state AS
WITH base AS (
    SELECT loc."State" AS state,
           m."MedName" AS medname,
           any_value(m."TherapeuticClass") AS tclass,
           sum(f."QuantitySold") AS qty
    FROM sdi."FactPharmacySales" f
    JOIN sdi."DimPharmacy" p   ON p."PharmacyKey" = f."PharmacyKey"
    JOIN sdi."DimLocation" loc ON loc."LocationKey" = p."LocationKey"
    JOIN sdi."DimMedicine" m   ON m."MedicineKey" = f."MedicineKey"
    WHERE f."PharmacyKey" <> -1 AND f."MedicineKey" <> -1 AND p."LocationKey" <> -1
    GROUP BY loc."State", m."MedName"
),
ranked AS (
    SELECT state, medname, tclass, qty,
           row_number() OVER (PARTITION BY state ORDER BY qty DESC, medname) AS rank_desc,
           row_number() OVER (PARTITION BY state ORDER BY qty ASC,  medname) AS rank_asc
    FROM base
)
SELECT state AS "State", medname AS "MedName", tclass AS "TherapeuticClass",
       qty AS "QuantitySold", rank_desc AS "Rank", 'Top' AS "TopOrBottom"
FROM ranked WHERE rank_desc <= 10
UNION ALL
SELECT state, medname, tclass, qty, rank_asc, 'Bottom'
FROM ranked WHERE rank_asc <= 10
ORDER BY "State", "TopOrBottom", "Rank";
