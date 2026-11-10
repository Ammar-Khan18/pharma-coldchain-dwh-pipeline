# Phase 1 assumption checks

Generated: 2026-11-11 01:17 from `/home/lenovo/pipeline/data`

## C1. Sales channel mix (how to derive Retail / Hospital / E-commerce)

_Hoping to see:_ Each SalesChannel x PharmacyType combo maps cleanly to one business channel; HospitalID is filled only for Hospital Pharmacy rows.

| SalesChannel | PharmacyType | hospital_id | SourceSystem | n_rows |
|---|---|---|---|---|
| Physical Pharmacy | Chain Pharmacy | empty | PHARMACY_POS | 173,485 |
| Physical Pharmacy | Independent Pharmacy | empty | PHARMACY_POS | 131,563 |
| Physical Pharmacy | Hospital Pharmacy | filled | PHARMACY_POS | 109,192 |
| Ecommerce | Chain Pharmacy | empty | ECOM_ORDER_PLATFORM | 48,736 |
| Ecommerce | Independent Pharmacy | empty | ECOM_ORDER_PLATFORM | 37,024 |

## C2. Hospital pharmacy -> hospital mapping (05 vs 06)

_Hoping to see:_ Every pharmacy that has a HospitalID maps to exactly one hospital, and it matches 06.HospitalPharmacyID.

| PharmacyID | n_hospitals | hospital_in_sales | hospital_in_demand | matches |
|---|---|---|---|---|
| PHR001 | 1 | HOSP001 | HOSP001 | True |
| PHR002 | 1 | HOSP002 | HOSP002 | True |
| PHR003 | 1 | HOSP003 | HOSP003 | True |
| PHR004 | 1 | HOSP004 | HOSP004 | True |
| PHR005 | 1 | HOSP005 | HOSP005 | True |
| PHR006 | 1 | HOSP006 | HOSP006 | True |
| PHR007 | 1 | HOSP007 | HOSP007 | True |
| PHR008 | 1 | HOSP008 | HOSP008 | True |
| PHR009 | 1 | HOSP009 | HOSP009 | True |
| PHR010 | 1 | HOSP010 | HOSP010 | True |
| PHR011 | 1 | HOSP011 | HOSP011 | True |
| PHR012 | 1 | HOSP012 | HOSP012 | True |

## C3. Pharmacy attributes stable per PharmacyID (dimension candidate)

_Hoping to see:_ 0 pharmacies with changing attributes -> dim_pharmacy can be built from distinct rows.

| pharmacies | pharmacies_with_changing_attrs |
|---|---|
| 60 | 0 |

## C4. Hospital attributes stable per HospitalID (dimension candidate)

_Hoping to see:_ 0 hospitals with changing attributes -> dim_hospital from distinct rows.

| hospitals | hospitals_with_changing_attrs |
|---|---|
| 12 | 0 |

## C5. Prescription flag vs PrescriptionID

_Hoping to see:_ Flag Y -> PrescriptionID filled; flag N -> empty. Flag should also match master PrescriptionClass.

| PrescriptionRequiredFlag | PrescriptionClass | rx_id | n_rows |
|---|---|---|---|
| N | OTC | empty | 37,316 |
| Y | Prescription | filled | 462,684 |

## C6. Money formulas in sales (counts of rows that break each formula, tolerance 1 cent)

_Hoping to see:_ All zeros -> we can trust the source amounts and use them as rules.

| n_rows | price_not_positive | qty_not_positive | gross_ne_price_x_qty | net_ne_gross_minus_disc | margin_ne_net_minus_cogs | cogs_ne_qty_x_wholesale | price_ne_master_rrp | bad_discount | negative_margin | avg_tax_rate |
|---|---|---|---|---|---|---|---|---|---|---|
| 500,000 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.06 |

## C7. Sales date checks

_Hoping to see:_ SalesDate = date part of SalesTimestampUTC; delivery to pharmacy before the sale; no expired stock sold; DaysToExpiryAtSale = ExpiryDate - SalesDate.

| bad_sales_date | bad_timestamp | date_ne_timestamp_date | delivered_after_sale | expired_at_sale | days_to_expiry_mismatch | first_sale | last_sale |
|---|---|---|---|---|---|---|---|
| 0 | 0 | 0 | 0 | 0 | 0 | 2023-01-30 | 2025-12-31 |

## C8. Returns consistency

_Hoping to see:_ ReturnFlag=Y <-> ReturnedQuantityPacks>0 <-> SaleStatus='Partially returned'.

| ReturnFlag | SaleStatus | ReturnedQuantityPacks | n_rows |
|---|---|---|---|
| N | Completed | 0 | 494,028 |
| Y | Partially returned | 1 | 5,972 |

## C9. E-commerce delivery status vs channel

_Hoping to see:_ 'Not applicable' only for physical sales.

| SalesChannel | EcommerceDeliveryStatus | n_rows |
|---|---|---|
| Ecommerce | Delivered | 64,162 |
| Ecommerce | Returned to sender | 21,598 |
| Physical Pharmacy | Not applicable | 414,240 |

## C10. Medicine attributes repeated in 05/06 agree with master

_Hoping to see:_ All zeros -> we drop GenericName/DiseaseCategory/GTIN14 from the facts and take them from dim_medicine.

| src | orphan_medicine | generic_mismatch | disease_mismatch | gtin_mismatch |
|---|---|---|---|---|
| sales | 0 | 0 | 0 | 0 |
| demand | 0 | 0 | 0 | 0 |

## C11. Hospital demand grain

_Hoping to see:_ rows = ids = grain_combos = 12 x 63 x 36 = 27,216 and 0 bad months.

| n_rows | ids | grain_combos | hospitals | medicines | months | first_month | last_month | bad_month |
|---|---|---|---|---|---|---|---|---|
| 27,216 | 27,216 | 27,216 | 12 | 63 | 36 | 2023-01-01 | 2025-12-01 | 0 |

## C12. Hospital demand quantity rules (counts of rows that break each candidate rule)

_Hoping to see:_ Tells us which stock-balance / service-level formula the source actually uses.

| n_rows | any_negative | approved_gt_requested | received_gt_approved | consumed_gt_dispensed | close_ne_open_plus_rec_minus_disp_minus_waste | close_ne_same_floored_at_0 | opening_ne_prev_closing | unfulfilled_ne_req_minus_rec | sl_ne_rec_over_req | sl_ne_disp_over_disp_plus_unf | sl_out_of_range | stockout_days_gt_month | avg_consumed_over_forecast |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 27,216 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 27,123 | 27,123 | 0 | 0 | 0 | 1.009 |

## C13. Are disease-level measures repeated for every medicine of a disease?

_Hoping to see:_ If groups_where_value_differs = 0, EstimatedDiseaseCases etc. are per hospital-disease-month and must NOT be summed across medicines.

| hospital_disease_month_groups | groups_where_value_differs |
|---|---|
| 3,024 | 3,024 |

## C14. Junk dimension size (distinct combos of low-cardinality sales flags)

_Hoping to see:_ A few hundred combos at most -> one small junk dimension is fine.

| distinct_combos |
|---|
| 2,889 |

## C15. Master price ladder

_Hoping to see:_ UnitManufacturingCost <= Wholesale <= RRP for every medicine.

| medicines | cost_gt_wholesale | wholesale_gt_rrp | bad_temp_range | gtin_not_14_chars |
|---|---|---|---|---|
| 63 | 0 | 0 | 0 | 0 |

## Allowed values (domain rules)

- **sales.SalesChannel**: Physical Pharmacy (414,240), Ecommerce (85,760)
- **sales.PharmacyType**: Chain Pharmacy (222,221), Independent Pharmacy (168,587), Hospital Pharmacy (109,192)
- **sales.CustomerSegment**: General wellness (100,542), Pediatric household (100,084), Senior chronic care (100,083), Adult acute care (99,748), Adult chronic care (99,543)
- **sales.PayerType**: Government program (166,751), Insurance (166,434), Cash (130,292), Hospital formulary (36,523)
- **sales.PaymentMethod**: Card (181,205), Insurance claim (138,105), Cash (137,818), Digital wallet (42,872)
- **sales.PromotionCode**: None (420,276), SEASON5 (20,058), ONLINE10 (19,964), LOYALTY5 (19,959), WELLNESS8 (19,743)
- **sales.EcommerceDeliveryStatus**: Not applicable (414,240), Delivered (64,162), Returned to sender (21,598)
- **sales.SaleStatus**: Completed (494,028), Partially returned (5,972)
- **sales.SourceSystem**: PHARMACY_POS (414,240), ECOM_ORDER_PLATFORM (85,760)
- **sales.DeliveryOTIFFlag**: Y (457,676), N (42,324)
- **sales.ReturnFlag**: N (494,028), Y (5,972)
- **sales.PrescriptionRequiredFlag**: Y (462,684), N (37,316)
- **demand.HospitalType**: General Hospital (9,072), Academic Medical Center (9,072), Community Hospital (6,804), Specialty Hospital (2,268)
- **demand.TraumaLevel**: None (13,608), Level II (6,804), Level I (6,804)
- **demand.MedicationRequestStatus**: Completed (27,133), Partially fulfilled (83)
- **demand.FormularyStatus**: Formulary (23,328), Restricted (2,160), Non-formulary exception (1,728)
