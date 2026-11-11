-- =====================================================================
-- sdi_50_aggregates.sql  —  Phase 1 query layer: pre-aggregated summary tables
-- WBS 3.4 / 2.6. Runs in the DuckDB mart (schema sdi). Rebuilt every run
-- (CREATE OR REPLACE ... AS SELECT) so they always match the facts; the facts
-- are small enough that a full rebuild is cheap and avoids incremental drift.
--
-- These are the "optimized" read path: dashboard widgets read a few hundred
-- pre-summed rows instead of scanning 500k fact rows. The optimized query
-- variants in sql/queries/*_opt.sql read these tables.
--
-- Each table is ORDER BY its grain so DuckDB's per-row-group min/max zone maps
-- line up with how the widgets filter (by month, then channel/hospital/medicine).
-- fact_sales itself is left append-only with its primary key intact; the zone
-- maps it builds on insert plus these aggregates are the optimization, so the
-- fact is not physically re-sorted (that would drop its PK / append-only contract).
-- =====================================================================

-- agg_sales_month_channel : revenue / cost / margin by month by channel --------
CREATE OR REPLACE TABLE sdi.agg_sales_month_channel AS
SELECT
    dd.year_month,
    CAST(strftime(dd.month_start_date, '%Y%m%d') AS INTEGER) AS month_date_key,
    ch.channel_key, ch.channel_code, ch.channel_name, ch.channel_group,
    count(*)                        AS txns,
    sum(f.quantity_sold_packs)      AS units_sold,
    sum(f.returned_quantity_packs)  AS units_returned,
    sum(f.gross_sales_usd)          AS gross_sales_usd,
    sum(f.discount_usd)             AS discount_usd,
    sum(f.net_sales_usd)            AS net_sales_usd,
    sum(f.sales_tax_usd)            AS sales_tax_usd,
    sum(f.cogs_usd)                 AS cogs_usd,
    sum(f.gross_margin_usd)         AS gross_margin_usd,
    round(100.0 * sum(f.gross_margin_usd) / nullif(sum(f.net_sales_usd), 0), 2) AS margin_pct
FROM sdi.fact_sales f
JOIN sdi.dim_date    dd ON dd.date_key    = f.sale_date_key
JOIN sdi.dim_channel ch ON ch.channel_key = f.channel_key
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY dd.year_month, ch.channel_key;

-- agg_demand_month_hospital : forecast vs actual / unfulfilled by month by hosp -
CREATE OR REPLACE TABLE sdi.agg_demand_month_hospital AS
SELECT
    dd.year_month,
    CAST(strftime(dd.month_start_date, '%Y%m%d') AS INTEGER) AS month_date_key,
    h.hospital_key, h.hospital_id, h.hospital_name, h.hospital_type, h.bed_size_band,
    count(*)                        AS records,
    sum(f.forecast_demand_packs)    AS forecast_packs,
    sum(f.requested_qty_packs)      AS requested_packs,
    sum(f.approved_qty_packs)       AS approved_packs,
    sum(f.received_qty_packs)       AS received_packs,
    sum(f.consumed_qty_packs)       AS consumed_packs,
    sum(f.dispensed_qty_packs)      AS dispensed_packs,
    sum(f.unfulfilled_demand_packs) AS unfulfilled_packs,
    sum(f.stockout_days)            AS stockout_days,
    round(avg(f.service_level_pct), 2) AS avg_service_level_pct,
    round(sum(f.consumed_qty_packs) * 1.0 / nullif(sum(f.forecast_demand_packs), 0), 4) AS consumed_vs_forecast_ratio
FROM sdi.fact_hospital_demand f
JOIN sdi.dim_date     dd ON dd.date_key     = f.month_date_key
JOIN sdi.dim_hospital h  ON h.hospital_key  = f.hospital_key
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY dd.year_month, h.hospital_key;

-- agg_sales_medicine_month : units / revenue / margin by medicine by month -----
CREATE OR REPLACE TABLE sdi.agg_sales_medicine_month AS
SELECT
    dd.year_month,
    CAST(strftime(dd.month_start_date, '%Y%m%d') AS INTEGER) AS month_date_key,
    m.medicine_id, m.generic_name, m.therapeutic_class, m.disease_category,
    sum(f.quantity_sold_packs) AS units_sold,
    sum(f.net_sales_usd)       AS net_sales_usd,
    sum(f.gross_margin_usd)    AS gross_margin_usd
FROM sdi.fact_sales f
JOIN sdi.dim_date     dd ON dd.date_key     = f.sale_date_key
JOIN sdi.dim_medicine m  ON m.medicine_key  = f.medicine_key
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY m.medicine_id, dd.year_month;
