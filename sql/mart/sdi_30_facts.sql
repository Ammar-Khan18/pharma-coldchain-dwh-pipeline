-- =====================================================================
-- sdi_30_facts.sql  —  Phase 1 transform, STEP 3: load facts (DuckDB)
-- WBS 3.1. Reads the cleaned staging tables and the dimensions, resolves every
-- surrogate key, and APPENDS to the two facts. Both are append-only: the clean
-- staging tables already exclude natural keys that are in the fact, and the
-- ON CONFLICT (natural key) DO NOTHING is a second guard, so re-running never
-- double-loads. Unmatched lookups fall back to the -1 member, so no fact foreign
-- key is ever NULL. The run id is (SELECT etl_batch_id FROM stg._batch).
--
--   dim_date is role-played: sale_date / pharmacy_delivery_date / batch_expiry_date
--   dim_medicine is SCD2 — the version valid on the event date is chosen.
-- =====================================================================

-- ---------------------------------------------------------------------
-- fact_sales  (transaction grain: one clean row of 05)
-- ---------------------------------------------------------------------
INSERT INTO sdi.fact_sales
    (sales_transaction_id, sale_date_key, pharmacy_delivery_date_key, batch_expiry_date_key,
     medicine_key, pharmacy_key, hospital_key, channel_key, sales_profile_key,
     sales_timestamp_utc, pharmacy_order_id, pharmacy_delivery_id, prescription_id,
     production_batch_id, warehouse_lot_id, source_warehouse_id, source_system,
     quantity_sold_packs, returned_quantity_packs, net_quantity_packs, unit_retail_price_usd,
     gross_sales_usd, discount_usd, net_sales_usd, sales_tax_usd, cogs_usd, gross_margin_usd,
     days_to_expiry_at_sale, dq_warning_count, etl_batch_id)
SELECT
    c.sales_transaction_id,
    COALESCE(dsale.date_key, -1), COALESCE(ddel.date_key, -1), COALESCE(dexp.date_key, -1),
    COALESCE(m.medicine_key, -1), COALESCE(p.pharmacy_key, -1),
    CASE WHEN c.hospital_id IS NULL THEN -1 ELSE COALESCE(h.hospital_key, -1) END,
    COALESCE(ch.channel_key, -1), COALESCE(sp.sales_profile_key, -1),
    c.sales_ts, c.pharmacy_order_id, c.pharmacy_delivery_id, c.prescription_id,
    c.production_batch_id, c.warehouse_lot_id, c.source_warehouse_id, c.source_system,
    c.quantity_sold_packs, c.returned_quantity_packs,
    c.quantity_sold_packs - c.returned_quantity_packs,
    c.unit_retail_price_usd, c.gross_sales_usd, c.discount_usd, c.net_sales_usd,
    c.sales_tax_usd, c.cogs_usd, c.gross_margin_usd, c.days_to_expiry_at_sale,
    c.dq_warning_count, (SELECT etl_batch_id FROM stg._batch)
FROM stg._clean_sales c
LEFT JOIN sdi.dim_date     dsale ON dsale.full_date = c.sales_date
LEFT JOIN sdi.dim_date     ddel  ON ddel.full_date  = c.pharmacy_delivery_date
LEFT JOIN sdi.dim_date     dexp  ON dexp.full_date  = c.batch_expiry_date
LEFT JOIN sdi.dim_medicine m     ON m.medicine_id = c.medicine_id
                                AND c.sales_date BETWEEN m.valid_from AND m.valid_to
LEFT JOIN sdi.dim_pharmacy p     ON p.pharmacy_id = c.pharmacy_id
LEFT JOIN sdi.dim_hospital h     ON h.hospital_id = c.hospital_id
LEFT JOIN sdi.dim_channel  ch    ON ch.channel_code = c.channel_code
LEFT JOIN sdi.dim_sales_profile sp
       ON sp.prescription_required_flag = c.prescription_required_flag
      AND sp.customer_segment          = c.customer_segment
      AND sp.payer_type                = c.payer_type
      AND sp.payment_method            = c.payment_method
      AND sp.promotion_code            = c.promotion_code
      AND sp.ecommerce_delivery_status = c.ecommerce_delivery_status
      AND sp.return_flag               = c.return_flag
      AND sp.sale_status               = c.sale_status
      AND sp.delivery_otif_flag        = c.delivery_otif_flag
ON CONFLICT (sales_transaction_id) DO NOTHING;

-- ---------------------------------------------------------------------
-- fact_hospital_demand  (periodic snapshot grain: hospital x medicine x month)
-- ---------------------------------------------------------------------
INSERT INTO sdi.fact_hospital_demand
    (hospital_demand_record_id, month_date_key, hospital_key, medicine_key, demand_status_key,
     estimated_disease_cases, disease_related_admissions, outpatient_encounters,
     forecast_demand_packs, requested_qty_packs, approved_qty_packs, received_qty_packs,
     emergency_request_qty_packs, dispensed_qty_packs, consumed_qty_packs, wastage_qty_packs,
     unfulfilled_demand_packs, stockout_days, opening_stock_packs, closing_stock_packs,
     service_level_pct, avg_lead_time_days, demand_trend_index, forecast_error_packs,
     dq_warning_count, etl_batch_id)
SELECT
    c.hospital_demand_record_id,
    COALESCE(dm.date_key, -1), COALESCE(h.hospital_key, -1), COALESCE(m.medicine_key, -1),
    COALESCE(ds.demand_status_key, -1),
    c.estimated_disease_cases, c.disease_related_admissions, c.outpatient_encounters,
    c.forecast_demand_packs, c.requested_qty_packs, c.approved_qty_packs, c.received_qty_packs,
    c.emergency_request_qty_packs, c.dispensed_qty_packs, c.consumed_qty_packs, c.wastage_qty_packs,
    c.unfulfilled_demand_packs, c.stockout_days, c.opening_stock_packs, c.closing_stock_packs,
    c.service_level_pct, c.avg_lead_time_days, c.demand_trend_index,
    c.consumed_qty_packs - c.forecast_demand_packs,
    c.dq_warning_count, (SELECT etl_batch_id FROM stg._batch)
FROM stg._clean_demand c
LEFT JOIN sdi.dim_date     dm ON dm.full_date = c.demand_month
LEFT JOIN sdi.dim_hospital h  ON h.hospital_id = c.hospital_id
LEFT JOIN sdi.dim_medicine m  ON m.medicine_id = c.medicine_id
                             AND c.demand_month BETWEEN m.valid_from AND m.valid_to
LEFT JOIN sdi.dim_demand_status ds
       ON ds.medication_request_status = c.medication_request_status
      AND ds.formulary_status          = c.formulary_status
ON CONFLICT (hospital_demand_record_id) DO NOTHING;
