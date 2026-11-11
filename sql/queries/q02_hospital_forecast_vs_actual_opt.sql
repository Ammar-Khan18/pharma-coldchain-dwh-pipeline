-- q02 (OPTIMIZED): reads the pre-aggregated agg_demand_month_hospital.
SELECT year_month, hospital_name,
       forecast_packs,
       consumed_packs AS actual_consumed_packs,
       consumed_vs_forecast_ratio AS consumed_vs_forecast,
       unfulfilled_packs
FROM sdi.agg_demand_month_hospital
ORDER BY year_month, hospital_name;
