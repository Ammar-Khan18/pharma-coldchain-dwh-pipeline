-- q2_hospital_forecast_vs_actual (BASE): scans FactHospitalDemand.
-- Forecast vs actual per Year, Month, HospitalName, HospitalType.
-- ICUBeds / LicensedBeds / Occupancy_PCT repeat on every medicine row of a
-- hospital-month, so they are reduced with MAX / AVG and must NEVER be SUMmed.
SELECT d."Year", d."Month", h."HospitalName", h."HospitalType",
       sum(f."ForecastDemand")    AS forecast_demand,
       sum(f."ConsumedQty")       AS consumed_qty,
       sum(f."UnfulfilledDemand") AS unfulfilled_demand,
       sum(f."ConsumedQty") - sum(f."ForecastDemand") AS forecast_gap,
       (sum(f."ConsumedQty") - sum(f."ForecastDemand")) * 1.0
            / nullif(sum(f."ForecastDemand"), 0) AS forecast_error_pct,
       max(f."ICUBeds")       AS icu_beds,
       max(f."LicensedBeds")  AS licensed_beds,
       avg(f."Occupancy_PCT") AS avg_occupancy_pct
FROM sdi."FactHospitalDemand" f
JOIN sdi."DimDate"     d ON d."DateKey"     = f."DateKey"
JOIN sdi."DimHospital" h ON h."HospitalKey" = f."HospitalKey"
GROUP BY d."Year", d."Month", h."HospitalName", h."HospitalType"
ORDER BY d."Year", d."Month", h."HospitalName";
