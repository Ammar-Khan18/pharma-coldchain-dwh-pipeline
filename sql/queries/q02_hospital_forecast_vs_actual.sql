-- q02 (RAW): forecast vs actual consumption and unfulfilled demand by hospital by month.
-- Widget: "Hospital forecast vs actual". Scans fact_hospital_demand.
SELECT dd.year_month,
       h.hospital_name,
       sum(f.forecast_demand_packs)    AS forecast_packs,
       sum(f.consumed_qty_packs)       AS actual_consumed_packs,
       round(sum(f.consumed_qty_packs) * 1.0 / nullif(sum(f.forecast_demand_packs), 0), 3) AS consumed_vs_forecast,
       sum(f.unfulfilled_demand_packs) AS unfulfilled_packs
FROM sdi.fact_hospital_demand f
JOIN sdi.dim_date     dd ON dd.date_key    = f.month_date_key
JOIN sdi.dim_hospital h  ON h.hospital_key = f.hospital_key
GROUP BY dd.year_month, h.hospital_name
ORDER BY dd.year_month, h.hospital_name;
