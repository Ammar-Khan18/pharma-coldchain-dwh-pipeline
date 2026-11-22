-- q2_hospital_forecast_vs_actual (AGG): reads agg_hospital_forecast_month.
SELECT "Year", "Month", "HospitalName", "HospitalType",
       "ForecastDemand", "ConsumedQty", "UnfulfilledDemand", "ForecastGap",
       "ForecastErrorPct", "ICUBeds", "LicensedBeds", "AvgOccupancyPct"
FROM sdi.agg_hospital_forecast_month
ORDER BY "Year", "Month", "HospitalName";
