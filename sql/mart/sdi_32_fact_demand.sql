-- =====================================================================
-- sdi_32_fact_demand.sql  —  Phase 1 transform STEP 3b: FactHospitalDemand (DuckDB)
-- Grain: one row per hospital x medicine x month. Append-only (the clean step
-- already excluded (HospitalID, MedicineID, DemandMonth) already loaded).
--   DateKey     = first day of DemandMonth as YYYYMMDD
--   HospitalKey = lookup by HospitalID; else -1
--   MedicineKey = point-in-time SCD2 by lpad(GTIN14,14,'0') on the month's 1st day;
--                 else the IsCurrent version; else -1
--   AverageOccupancyRatePct -> Occupancy_PCT; *Packs columns renamed per schema.
--   etl_batch_id carried from the ODS. Insert ORDER BY DateKey.
-- =====================================================================
INSERT INTO sdi."FactHospitalDemand"
    ("DateKey", "HospitalKey", "MedicineKey", "Occupancy_PCT", "ICUBeds", "LicensedBeds",
     "EstimatedDiseaseCases", "DiseaseRelatedAdmissions", "OutpatientEncounters",
     "ForecastDemand", "RequestedQty", "ApprovedQty", "EmergencyRequestQty", "OpeningStock",
     "DispensedQty", "ConsumedQty", "WastageQty", "ClosingStock", "UnfulfilledDemand",
     "StockoutDays", "DemandTrendIndex", etl_batch_id)
SELECT
    CAST(strftime(c.demand_month, '%Y%m%d') AS INTEGER) AS date_key,
    COALESCE(h."HospitalKey", -1),
    COALESCE(m_pit."MedicineKey", m_cur."MedicineKey", -1),
    c.occupancy_pct, c.icu_beds, c.licensed_beds, c.estimated_disease_cases,
    c.disease_related_admissions, c.outpatient_encounters, c.forecast_demand, c.requested_qty,
    c.approved_qty, c.emergency_request_qty, c.opening_stock, c.dispensed_qty, c.consumed_qty,
    c.wastage_qty, c.closing_stock, c.unfulfilled_demand, c.stockout_days, c.demand_trend_index,
    c.src_etl_batch_id
FROM stg._clean_demand c
LEFT JOIN sdi."DimHospital" h
       ON h."HospitalID" = c.hospital_id AND h."HospitalKey" <> -1
LEFT JOIN sdi."DimMedicine" m_pit
       ON m_pit."GTIN14" = c.gtin14
      AND c.demand_month BETWEEN m_pit."EffectiveFrom" AND m_pit."EffectiveTo"
      AND m_pit."MedicineKey" <> -1
LEFT JOIN sdi."DimMedicine" m_cur
       ON m_cur."GTIN14" = c.gtin14
      AND m_cur."IsCurrent" = 'Y'
      AND m_cur."MedicineKey" <> -1
ORDER BY date_key;
