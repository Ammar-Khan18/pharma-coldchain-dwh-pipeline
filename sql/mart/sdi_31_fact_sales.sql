-- =====================================================================
-- sdi_31_fact_sales.sql  —  Phase 1 transform STEP 3a: FactPharmacySales (DuckDB)
-- Grain: one row per SalesTransactionID. Append-only (new rows only; the clean
-- step already excluded SalesTransactionIDs already in the fact).
--   DateKey      = SalesDate as YYYYMMDD
--   MedicineKey  = point-in-time SCD2 (MedicineID + SalesDate in [EffectiveFrom,EffectiveTo]);
--                  else the IsCurrent version; else -1
--   PharmacyKey  = lookup by (PharmacyID, SalesChannel) [decision R1]; else -1
--   NetSales = GrossSales - Discount ; GrossMargin = NetSales - COGS (computed in clean step)
--   MfgCost/MRP/ListTradePrice = master prices looked up by MedicineID
--   etl_batch_id carried from the ODS. Insert ORDER BY DateKey (zone-map friendly).
-- =====================================================================
INSERT INTO sdi."FactPharmacySales"
    ("DateKey", "MedicineKey", "PharmacyKey", "SalesTransactionID", "CustomerSegment",
     "QuantitySold", "ReturnedQty", "GrossSales", "Discount", "NetSales", "SalesTax",
     "COGS", "GrossMargin", "DaysToExpiryAtSale", "MfgCost", "MRP", "ListTradePrice",
     etl_batch_id)
SELECT
    CAST(strftime(c.sales_date, '%Y%m%d') AS INTEGER) AS date_key,
    COALESCE(m_pit."MedicineKey", m_cur."MedicineKey", -1),
    COALESCE(p."PharmacyKey", -1),
    c.sales_transaction_id,
    c.customer_segment,
    c.quantity_sold, c.returned_qty, c.gross_sales, c.discount, c.net_sales,
    c.sales_tax, c.cogs, c.gross_margin, c.days_to_expiry_at_sale,
    mp.mfg_cost, mp.mrp, mp.list_trade_price,
    c.src_etl_batch_id
FROM stg._clean_sales c
LEFT JOIN sdi."DimMedicine" m_pit
       ON m_pit."MedicineID" = c.medicine_id
      AND c.sales_date BETWEEN m_pit."EffectiveFrom" AND m_pit."EffectiveTo"
      AND m_pit."MedicineKey" <> -1
LEFT JOIN sdi."DimMedicine" m_cur
       ON m_cur."MedicineID" = c.medicine_id
      AND m_cur."IsCurrent" = 'Y'
      AND m_cur."MedicineKey" <> -1
LEFT JOIN sdi."DimPharmacy" p
       ON p."PharmacyID" = c.pharmacy_id
      AND p."SalesChannel" = c.sales_channel
      AND p."PharmacyKey" <> -1
LEFT JOIN stg._clean_master mp ON mp.medicine_id = c.medicine_id
ORDER BY date_key
ON CONFLICT ("SalesTransactionID") DO NOTHING;
