-- =====================================================================
-- Milestone 2  BI views for Power BI (sdi_business.pbix)
-- File: sql/postgres/07_bi_views.sql          Run as ida_user. Safe to re-run.
--
-- One view per dashboard visual, in schema `mart`, with friendly (snake_case)
-- column names so a beginner can drag fields straight onto a Power BI canvas.
-- All SELECT is granted to bi_reader (the read-only Power BI / Grafana login).
--
-- These views read the serving copies that serving/publish_mart.py refreshes
-- (mart.FactPharmacySales, mart.FactHospitalDemand and the Dim*/agg_* tables).
-- publish_mart.py DROPs and recreates those tables when their columns change,
-- which would fail while a view depends on them, so publish_mart.py now drops
-- every mart view before the refresh and re-runs THIS FILE afterwards. Keep this
-- file pure SQL (no psql backslash commands) so psycopg2 can execute it whole.
--
-- SCD2 note: DimMedicine is Type 2 (on PresClass + ProductStatus). The facts
-- carry the MedicineKey that was in effect at the event, so every join below goes
-- fact -> DimMedicine on MedicineKey (the correct version). v_medicine_movement
-- then groups by MedName/TherapeuticClass, so two versions of one medicine inside
-- a month collapse to a single, correctly-ranked movement row.
--
-- Ubuntu (WSL):
--   PGPASSWORD=ida_pass psql -h localhost -U ida_user -d ida_staging -f ~/pipeline/sql/postgres/07_bi_views.sql
-- =====================================================================

-- Idempotent: drop first so a changed column list never blocks CREATE OR REPLACE.
DROP VIEW IF EXISTS mart.v_kpi_latest_month       CASCADE;
DROP VIEW IF EXISTS mart.v_channel_month          CASCADE;
DROP VIEW IF EXISTS mart.v_hospital_forecast_month CASCADE;
DROP VIEW IF EXISTS mart.v_medicine_movement      CASCADE;
DROP VIEW IF EXISTS mart.v_refresh_status         CASCADE;

-- ---------------------------------------------------------------------
-- v_kpi_latest_month  — headline cards for page 1 ("vs last month").
-- ONE row: the latest data month side by side with the previous data month,
-- plus month-over-month deltas. Revenue = SUM(NetSales), units = SUM(QuantitySold),
-- gross margin % = SUM(GrossMargin)/SUM(NetSales) (SUM/SUM, never averaged),
-- unfulfilled demand = SUM(UnfulfilledDemand) from the hospital-demand fact.
-- "Latest" / "previous" = the two most recent months actually present in sales.
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_kpi_latest_month AS
WITH sales_m AS (
    SELECT d."Year" AS yr, d."Month" AS mo,
           (d."Year" * 100 + d."Month") AS ym,
           SUM(f."NetSales")    AS revenue,
           SUM(f."QuantitySold") AS units,
           SUM(f."GrossMargin") AS gross_margin
    FROM mart."FactPharmacySales" f
    JOIN mart."DimDate" d ON d."DateKey" = f."DateKey"
    WHERE f."DateKey" <> -1
    GROUP BY d."Year", d."Month"
),
demand_m AS (
    SELECT (d."Year" * 100 + d."Month") AS ym,
           SUM(f."UnfulfilledDemand") AS unfulfilled_demand
    FROM mart."FactHospitalDemand" f
    JOIN mart."DimDate" d ON d."DateKey" = f."DateKey"
    WHERE f."DateKey" <> -1
    GROUP BY d."Year", d."Month"
),
m AS (
    SELECT s.*, dm.unfulfilled_demand,
           to_char(make_date(s.yr, s.mo, 1), 'Mon YYYY') AS month_label,
           ROW_NUMBER() OVER (ORDER BY s.ym DESC) AS rn
    FROM sales_m s
    LEFT JOIN demand_m dm ON dm.ym = s.ym
)
SELECT
    cur.ym          AS month_key,
    cur.month_label AS month,
    prv.ym          AS prev_month_key,
    prv.month_label AS prev_month,
    cur.revenue     AS revenue,
    prv.revenue     AS revenue_prev,
    (cur.revenue - prv.revenue) / NULLIF(prv.revenue, 0)                 AS revenue_mom_pct,
    cur.units       AS units,
    prv.units       AS units_prev,
    (cur.units - prv.units) * 1.0 / NULLIF(prv.units, 0)                 AS units_mom_pct,
    cur.gross_margin / NULLIF(cur.revenue, 0)                            AS gross_margin_pct,
    prv.gross_margin / NULLIF(prv.revenue, 0)                            AS gross_margin_pct_prev,
    (cur.gross_margin / NULLIF(cur.revenue, 0))
        - (prv.gross_margin / NULLIF(prv.revenue, 0))                    AS gross_margin_pct_delta,
    cur.unfulfilled_demand        AS unfulfilled_demand,
    prv.unfulfilled_demand        AS unfulfilled_demand_prev,
    (cur.unfulfilled_demand - prv.unfulfilled_demand) * 1.0
        / NULLIF(prv.unfulfilled_demand, 0)                             AS unfulfilled_demand_mom_pct
FROM (SELECT * FROM m WHERE rn = 1) cur
CROSS JOIN (SELECT * FROM m WHERE rn = 2) prv;

-- ---------------------------------------------------------------------
-- v_channel_month  — page 1: revenue / cost / gross margin / margin %
-- by sales channel by month. Mirrors q1_channel_margin with friendly names.
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_channel_month AS
SELECT
    (d."Year" * 100 + d."Month")                   AS month_key,
    d."Year"                                        AS year,
    d."Month"                                       AS month_number,
    d."MonthName"                                   AS month_name,
    make_date(d."Year", d."Month", 1)              AS month_start,
    to_char(make_date(d."Year", d."Month", 1), 'Mon YYYY') AS month_label,
    p."SalesChannel"                               AS channel,
    SUM(f."NetSales")                              AS revenue,
    SUM(f."COGS")                                  AS cost,
    SUM(f."GrossMargin")                           AS gross_margin,
    SUM(f."GrossMargin") / NULLIF(SUM(f."NetSales"), 0) AS gross_margin_pct
FROM mart."FactPharmacySales" f
JOIN mart."DimDate"     d ON d."DateKey"     = f."DateKey"
JOIN mart."DimPharmacy" p ON p."PharmacyKey" = f."PharmacyKey"
WHERE f."DateKey" <> -1
GROUP BY d."Year", d."Month", d."MonthName", p."SalesChannel";

-- ---------------------------------------------------------------------
-- v_hospital_forecast_month  — page 2: forecast vs actual + unfulfilled demand
-- by hospital by month. "Actual" = ConsumedQty. Ratio = actual / forecast
-- (1.0 = on target, <1 over-forecast, >1 under-forecast). State is included for
-- the state slicer. Beds/occupancy repeat per medicine so they are NOT summed
-- (shown elsewhere); this view is the forecast story only.
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_hospital_forecast_month AS
SELECT
    (d."Year" * 100 + d."Month")                   AS month_key,
    d."Year"                                        AS year,
    d."Month"                                       AS month_number,
    make_date(d."Year", d."Month", 1)              AS month_start,
    to_char(make_date(d."Year", d."Month", 1), 'Mon YYYY') AS month_label,
    h."HospitalName"                               AS hospital,
    h."HospitalType"                               AS hospital_type,
    loc."State"                                    AS state,
    SUM(f."ForecastDemand")                        AS forecast_demand,
    SUM(f."ConsumedQty")                           AS actual_consumed,
    SUM(f."ConsumedQty") * 1.0 / NULLIF(SUM(f."ForecastDemand"), 0) AS actual_vs_forecast_ratio,
    SUM(f."UnfulfilledDemand")                     AS unfulfilled_demand
FROM mart."FactHospitalDemand" f
JOIN mart."DimDate"     d   ON d."DateKey"      = f."DateKey"
JOIN mart."DimHospital" h   ON h."HospitalKey"  = f."HospitalKey"
LEFT JOIN mart."DimLocation" loc ON loc."LocationKey" = h."LocationKey"
WHERE f."DateKey" <> -1 AND f."HospitalKey" <> -1
GROUP BY d."Year", d."Month", h."HospitalName", h."HospitalType", loc."State";

-- ---------------------------------------------------------------------
-- v_medicine_movement  — page 3: units sold by medicine, therapeutic class
-- and state per month, with a fast-mover rank (1 = best seller in that
-- state-month) and a slow-mover rank (1 = worst seller). Pharmacy sales only,
-- mapped to state via DimPharmacy -> DimLocation.
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_medicine_movement AS
WITH base AS (
    SELECT
        (d."Year" * 100 + d."Month")               AS month_key,
        d."Year"                                    AS year,
        d."Month"                                   AS month_number,
        make_date(d."Year", d."Month", 1)          AS month_start,
        to_char(make_date(d."Year", d."Month", 1), 'Mon YYYY') AS month_label,
        m."MedName"                                AS medicine,
        m."TherapeuticClass"                       AS therapeutic_class,
        loc."State"                                AS state,
        SUM(f."QuantitySold")                      AS units_sold
    FROM mart."FactPharmacySales" f
    JOIN mart."DimDate"     d   ON d."DateKey"     = f."DateKey"
    JOIN mart."DimMedicine" m   ON m."MedicineKey" = f."MedicineKey"
    JOIN mart."DimPharmacy" p   ON p."PharmacyKey" = f."PharmacyKey"
    JOIN mart."DimLocation" loc ON loc."LocationKey" = p."LocationKey"
    WHERE f."DateKey" <> -1 AND f."MedicineKey" <> -1
      AND f."PharmacyKey" <> -1 AND p."LocationKey" <> -1
    GROUP BY d."Year", d."Month", m."MedName", m."TherapeuticClass", loc."State"
)
SELECT base.*,
       RANK() OVER (PARTITION BY month_key, state ORDER BY units_sold DESC) AS fast_mover_rank,
       RANK() OVER (PARTITION BY month_key, state ORDER BY units_sold ASC)  AS slow_mover_rank
FROM base;

-- ---------------------------------------------------------------------
-- v_refresh_status  — "Data as of" card on every page. Latest successful
-- pipeline run time, latest data month in the facts, and the two fact row
-- counts (so a card visibly changes after a refresh adds a month).
-- Reads meta.pipeline_run; the view runs as its owner (ida_user), who can see it.
-- ---------------------------------------------------------------------
CREATE VIEW mart.v_refresh_status AS
SELECT
    (SELECT max(finished_at) FROM meta.pipeline_run WHERE status = 'SUCCESS')
        AS last_refresh_at,
    (SELECT etl_batch_id FROM meta.pipeline_run WHERE status = 'SUCCESS'
      ORDER BY finished_at DESC NULLS LAST LIMIT 1)
        AS last_batch_id,
    (SELECT to_char(make_date(d."Year", d."Month", 1), 'Mon YYYY')
       FROM mart."FactPharmacySales" f
       JOIN mart."DimDate" d ON d."DateKey" = f."DateKey"
      WHERE f."DateKey" <> -1
      ORDER BY (d."Year" * 100 + d."Month") DESC LIMIT 1)
        AS latest_data_month,
    (SELECT max(d."Year" * 100 + d."Month")
       FROM mart."FactPharmacySales" f
       JOIN mart."DimDate" d ON d."DateKey" = f."DateKey"
      WHERE f."DateKey" <> -1)
        AS latest_data_month_key,
    (SELECT count(*) FROM mart."FactPharmacySales")  AS pharmacy_sales_rows,
    (SELECT count(*) FROM mart."FactHospitalDemand") AS hospital_demand_rows;

-- ---------------------------------------------------------------------
-- Grants — the read-only BI login can SELECT every view (and nothing else).
-- ---------------------------------------------------------------------
GRANT USAGE ON SCHEMA mart TO bi_reader;
GRANT SELECT ON mart.v_kpi_latest_month        TO bi_reader;
GRANT SELECT ON mart.v_channel_month           TO bi_reader;
GRANT SELECT ON mart.v_hospital_forecast_month TO bi_reader;
GRANT SELECT ON mart.v_medicine_movement       TO bi_reader;
GRANT SELECT ON mart.v_refresh_status          TO bi_reader;
