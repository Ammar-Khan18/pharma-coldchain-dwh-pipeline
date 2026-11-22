# Oversampled data — data dictionary

This folder holds the **generator output** for the Phase 1 refresh demo — the
synthetic "new month" CSVs produced by [`generator/generate.py`](../generator/generate.py)
(WBS 2.1). These are *not* the seven original source files; they are appended to
history so the warehouse and dashboards visibly step forward on a refresh.

> The **design source of truth** is the hand-edited workbook
> [`Milestone-1-Deliverables/Milestone.1.SDI.DWH.Excel.xlsx`](../Milestone-1-Deliverables/Milestone.1.SDI.DWH.Excel.xlsx)
> (never modified or regenerated); [`docs/phase1_sdi_design.md`](../docs/phase1_sdi_design.md)
> is its text companion.

Files in this folder:

| File | Source family | Data rows | Grain |
| --- | --- | ---: | --- |
| `01_master_data__gen_2026-01.20261115T200834.csv` | 01 medicine master | 63 | 1 medicine |
| `05_pharmacy_sales_data__gen_2026-01.20261115T200835.csv` | 05 pharmacy sales | 13,894 (13,889 valid + 5 bad) | 1 sales transaction |
| `06_hospital_demand_data__gen_2026-01.20261115T200834.csv` | 06 hospital demand | 756 | 1 hospital × medicine × month |

The `__gen_<period>` suffix marks a generated file; the trailing
`.<timestamp>` is the archive stamp added when the file-watcher moved it out of
`landing/` after ingestion. The column layout, text formats, GTIN-14 leading
zero and date formats are **byte-identical** to the real source files, so the
ingestion and validation layers treat them exactly like real data.

**Validation rule IDs** (`M*`, `S*`, `H*`) reference the rulebook in
[`docs/phase1_sdi_design.md`](../docs/phase1_sdi_design.md) §4. Action is
**REJECT** (row quarantined in `ods.rejected_rows`, never enters the mart) or
**WARN** (row loads, a per-rule tally logged to `meta.dq_log`).

---

## 1. `01_master_data__gen_2026-01` — medicine master

One row per medicine. Feeds `DimMedicine` (conformed, **SCD Type 2 on `PrescriptionClass`
and `ProductStatus` only**). A change in either closes the old version and opens a new
current one; prices are **Type 1** (overwritten, and copied per sale onto the fact).

| # | Column | Type | Meaning | Example | Rule |
| ---: | --- | --- | --- | --- | --- |
| 1 | `MedicineID` | text (code) | Business key of the medicine | `MED001` | **M1** (not empty, unique) |
| 2 | `InternalSKU` | text (code) | Internal stock-keeping unit | `SKU-01-0001` | — |
| 3 | `GTIN14` | text (14 digits) | Global Trade Item Number, leading zero preserved | `09506000000015` | **M6** (digits only, ≤14, zero-padded) |
| 4 | `GenericName` | text | Non-proprietary drug name | `Metformin` | — (Type 1 attribute) |
| 5 | `FictionalBrandName` | text | Brand name | `ClariMetform01` | — |
| 6 | `DiseaseCategory` | text | Disease area treated | `Diabetes Mellitus` | — |
| 7 | `ICD10Category` | text (code) | ICD-10 disease code | `E11` | — |
| 8 | `ATCCode` | text (code) | WHO Anatomical Therapeutic Chemical code | `A10BA02` | — |
| 9 | `TherapeuticClass` | text | Pharmacological class | `Biguanide` | — |
| 10 | `DosageForm` | text | Physical form | `Tablet` | — |
| 11 | `Strength` | text | Dose strength | `500 mg` | — |
| 12 | `RouteOfAdministration` | text | How it is given | `Oral` | — |
| 13 | `PackSize` | integer | Units per pack | `30` | — |
| 14 | `BaseUnitOfMeasure` | text | Base unit | `pack` | — |
| 15 | `PrescriptionClass` | text (enum) | Prescription / OTC | `Prescription` | **M5** (∈ {Prescription, OTC}) |
| 16 | `ControlledMedicineFlag` | text (Y/N) | Controlled substance? | `N` | **M5** (Y/N only) |
| 17 | `ColdChainFlag` | text (Y/N) | Cold-chain medicine? | `N` | **M5** (Y/N only) |
| 18 | `StorageMinTempC` | numeric (°C) | Min storage temperature | `15` | **M4** (`min` < `max`) |
| 19 | `StorageMaxTempC` | numeric (°C) | Max storage temperature | `25` | **M4** (`min` < `max`) |
| 20 | `MaxHumidityPct` | numeric (%) | Max storage humidity | `65` | — |
| 21 | `ShelfLifeMonths` | integer | Shelf life in months | `24` | — |
| 22 | `MinimumRemainingShelfLifeDays` | integer | Min remaining shelf life at dispatch | `270` | — |
| 23 | `PrimarySupplierID` | text (code) | Primary supplier | `SUP001` | — |
| 24 | `PrimaryPlantID` | text (code) | Primary manufacturing plant | `PLT02` | — |
| 25 | `ManufacturingLeadTimeDays` | integer | Lead time to manufacture | `21` | — |
| 26 | `StandardBatchSizePacks` | integer | Standard batch size | `15000` | — |
| 27 | `SafetyStockDays` | integer | Safety stock cover | `35` | — |
| 28 | `ReorderReviewCycleDays` | integer | Reorder review cadence | `7` | — |
| 29 | `UnitManufacturingCostUSD` | numeric (USD) | Unit manufacturing cost | `0.55` | **M2** (>0), **M3** (≤ wholesale, WARN) |
| 30 | `WholesalePriceUSD` | numeric (USD) | Wholesale price | `2.2` | **M2** (>0), **M3** (cost ≤ this ≤ RRP, WARN) |
| 31 | `RecommendedRetailPriceUSD` | numeric (USD) | Recommended retail price → `FactPharmacySales.ListTradePrice` (copied per sale; **Type 1** in DimMedicine) | `2.9` | **M2** (>0), **M3** (≥ wholesale, WARN) |
| 32 | `ProductStatus` | text (enum) | Lifecycle status | `Active` | — |
| 33 | `EffectiveFromDate` | date (YYYY-MM-DD) | First valid-from of SCD2 | `2023-01-01` | — |
| 34 | `SourceSystem` | text | Originating system | `ERP_PRODUCT_MASTER` | — |

---

## 2. `05_pharmacy_sales_data__gen_2026-01` — pharmacy sales

One row per sales transaction. Feeds `FactPharmacySales` (**transaction fact**, grain = one
`SalesTransactionID`). IDs continue the historical sequence; `SalesDate` is spread across the
new month and `BatchExpiryDate` is pushed into the future so nothing is sold expired.
(The junk dimensions of the old model were removed; low-cardinality flags are either kept as
degenerate columns — `CustomerSegment` — or dropped.)

| # | Column | Type | Meaning | Example | Rule |
| ---: | --- | --- | --- | --- | --- |
| 1 | `SalesTransactionID` | text (code) | Transaction business key (degenerate dim) | `SALE-000500001` | **S1** (not empty, unique, not already loaded) → REJECT |
| 2 | `SalesDate` | date (YYYY-MM-DD) | Date of sale | `2026-01-05` | **S4** (valid date, 2023-01-01…run date) → REJECT |
| 3 | `SalesTimestampUTC` | timestamp (ISO-8601 Z) | Sale timestamp | `2026-01-05T14:05:35Z` | **S5** (date part = `SalesDate`, WARN) |
| 4 | `SalesChannel` | text (enum) | Source channel; part of the `DimPharmacy` grain `(PharmacyID, SalesChannel)` | `Ecommerce` | **S16** (known value, WARN) |
| 5 | `PharmacyID` | text (code) | Selling pharmacy (→ `DimPharmacy`) | `PHR013` | **S3** (not empty) → REJECT |
| 6 | `PharmacyGLN` | text (13 digits) | Pharmacy Global Location Number | `0950600300133` | — |
| 7 | `PharmacyName` | text | Pharmacy name | `WellSpring Pharmacy 13` | — |
| 8 | `PharmacyType` | text (enum) | Pharmacy type | `Chain Pharmacy` | **S15** (vs `HospitalID`, WARN), **S16** |
| 9 | `HospitalID` | text (code) | Hospital, if a hospital-pharmacy sale (else empty) | *(empty)* | **S15** (filled ⇔ Hospital Pharmacy, WARN) |
| 10 | `PharmacyCity` | text | Pharmacy city | `San Diego` | — |
| 11 | `PharmacyState` | text | Pharmacy state | `CA` | — |
| 12 | `CountryCode` | text (ISO-2) | Country | `US` | — |
| 13 | `PharmacyOrderID` | text (code) | Order ID (degenerate dim) | `PHO-0001683` | — |
| 14 | `PharmacyDeliveryID` | text (code) | Delivery ID (degenerate dim) | `PHD-0001683` | — |
| 15 | `PharmacyDeliveryDate` | date (YYYY-MM-DD) | Delivery date to pharmacy | `2023-12-12` | **S12** (≤ `SalesDate`, WARN) |
| 16 | `DeliveryQuantityPacks` | integer | Packs in the delivery (belongs to delivery; dropped from fact) | `2455` | — |
| 17 | `DeliveryOTIFFlag` | text (Y/N) | On-time-in-full delivery flag | `Y` | — |
| 18 | `WarehouseLotID` | text (code) | Warehouse lot (degenerate / Phase 2) | `WHLOT-0000427` | — |
| 19 | `SourceWarehouseID` | text (code) | Source warehouse (Phase 2) | `WH004` | — |
| 20 | `ProductionBatchID` | text (code) | Production batch (degenerate / Phase 2) | `B23-PLT02-000233` | — |
| 21 | `MedicineID` | text (code) | Medicine sold (→ `DimMedicine`) | `MED027` | **S2** (not empty, exists in `DimMedicine`) → REJECT |
| 22 | `GTIN14` | text (14 digits) | Trade item number (repeated; dropped from fact) | `09506000000275` | — |
| 23 | `DiseaseCategory` | text | Repeated medicine attribute (dropped from fact) | `Respiratory Disease` | — |
| 24 | `GenericName` | text | Repeated medicine attribute (dropped from fact) | `Acetylcysteine` | — |
| 25 | `BatchExpiryDate` | date (YYYY-MM-DD) | Expiry of the batch sold | `2026-11-20` | **S14** (≥ `SalesDate`, WARN) |
| 26 | `DaysToExpiryAtSale` | integer | Days to expiry at sale (non-additive) | `319` | — |
| 27 | `QuantitySoldPacks` | integer | Packs sold | `1` | **S7** (≥1) → REJECT |
| 28 | `UnitRetailPriceUSD` | numeric (USD) | Unit retail price (non-additive) | `8.58` | **S6** (>0) → REJECT |
| 29 | `GrossSalesAmountUSD` | numeric (USD) | Gross = price × qty | `8.58` | **S8** (= price×qty ±0.01, WARN) |
| 30 | `DiscountAmountUSD` | numeric (USD) | Discount | `0` | **S9** (0 ≤ disc ≤ gross, WARN) |
| 31 | `NetSalesAmountUSD` | numeric (USD) | Net = gross − discount | `8.58` | **S9** (= gross − disc ±0.01, WARN) |
| 32 | `SalesTaxUSD` | numeric (USD) | Sales tax | `0.51` | — |
| 33 | `CostOfGoodsSoldUSD` | numeric (USD) | COGS | `6.5` | — |
| 34 | `GrossMarginUSD` | numeric (USD) | Margin = net − COGS | `2.08` | **S10** (= net − COGS ±0.01, WARN) |
| 35 | `PromotionCode` | text (code) | Promo code; empty/`None` = no promo (junk dims removed; not carried) | `None` | — |
| 36 | `PrescriptionRequiredFlag` | text (Y/N) | Rx required? | `N` | **S13** (Y ⇒ `PrescriptionID` filled, WARN) |
| 37 | `PrescriptionID` | text (code) | Prescription ID; empty for OTC (degenerate dim) | *(empty)* | **S13** (WARN) |
| 38 | `CustomerSegment` | text (enum) | Customer segment (**degenerate dimension** on FactPharmacySales) | `Adult chronic care` | **S16** (WARN) |
| 39 | `PayerType` | text (enum) | Payer (junk dims removed; not carried to the mart) | `Insurance` | **S16** (WARN) |
| 40 | `PaymentMethod` | text (enum) | Payment method (junk dims removed; not carried to the mart) | `Digital wallet` | **S16** (WARN) |
| 41 | `EcommerceDeliveryStatus` | text (enum) | E-commerce delivery status (junk dims removed; not carried to the mart) | `Delivered` | **S16** (WARN) |
| 42 | `ReturnFlag` | text (Y/N) | Any return on this sale? | `N` | **S11** (Y ⇔ returned>0, WARN) |
| 43 | `ReturnedQuantityPacks` | integer | Packs returned | `0` | **S11** (0 ≤ ret ≤ sold, WARN) |
| 44 | `SaleStatus` | text (enum) | Sale lifecycle status (junk dims removed; not carried to the mart) | `Completed` | **S16** (WARN) |
| 45 | `SourceSystem` | text | Originating system | `ECOM_ORDER_PLATFORM` | — |

---

## 3. `06_hospital_demand_data__gen_2026-01` — hospital demand

One row per hospital × medicine × month (a complete grain: 12 hospitals ×
63 medicines = 756 rows). Feeds `FactHospitalDemand` (**periodic snapshot**).
Opening/closing stock are **semi-additive** (sum across hospitals, never months).
`ICUBeds`, `LicensedBeds` and `AverageOccupancyRatePct` repeat on every medicine row of a
hospital-month, so they are taken with **MAX/AVG and never summed**.

| # | Column | Type | Meaning | Example | Rule |
| ---: | --- | --- | --- | --- | --- |
| 1 | `HospitalDemandRecordID` | text (code) | Record business key (degenerate dim) | `HDEM-00027217` | **H1** (not empty, unique, not already loaded) → REJECT |
| 2 | `DemandMonth` | date (1st of month) | Snapshot month | `2026-01-01` | **H2/H3** (unique grain; valid 1st-of-month) → REJECT |
| 3 | `HospitalID` | text (code) | Hospital (→ `DimHospital`) | `HOSP001` | **H4** (not empty) → REJECT |
| 4 | `HospitalGLN` | text (13 digits) | Hospital Global Location Number | `0950600400017` | — |
| 5 | `HospitalName` | text | Hospital name | `University Medical Center` | — |
| 6 | `HospitalType` | text | Hospital type | `Academic Medical Center` | — |
| 7 | `HospitalPharmacyID` | text (code) | Hospital's pharmacy | `PHR001` | — |
| 8 | `City` | text | City | `Philadelphia` | — |
| 9 | `State` | text | State | `PA` | — |
| 10 | `CountryCode` | text (ISO-2) | Country | `US` | — |
| 11 | `LicensedBeds` | integer | Licensed beds; kept on FactHospitalDemand (**MAX, never SUM**) | `850` | — |
| 12 | `ICUBeds` | integer | ICU beds | `96` | — |
| 13 | `AverageOccupancyRatePct` | numeric (%) | Average occupancy | `68` | — |
| 14 | `TraumaLevel` | text (enum) | Trauma level; empty = not designated | `Level I` | — |
| 15 | `CatchmentPopulation` | integer | Catchment population | `1800000` | — |
| 16 | `MedicineID` | text (code) | Medicine (→ `DimMedicine`) | `MED001` | **H4** (exists in `DimMedicine`) → REJECT |
| 17 | `GTIN14` | text (14 digits) | Trade item number | `09506000000015` | — |
| 18 | `GenericName` | text | Medicine name | `Metformin` | — |
| 19 | `DiseaseCategory` | text | Disease area | `Diabetes Mellitus` | — |
| 20 | `ICD10Category` | text (code) | ICD-10 code | `E11` | — |
| 21 | `EstimatedDiseaseCases` | integer | Estimated cases in catchment | `3562` | — |
| 22 | `DiseaseRelatedAdmissions` | integer | Related admissions | `1354` | — |
| 23 | `OutpatientEncounters` | integer | Outpatient encounters | `5423` | — |
| 24 | `ForecastDemandPacks` | integer | Forecast demand (additive) | `222` | **H5** (≥0) → REJECT |
| 25 | `RequestedQuantityPacks` | integer | Requested (additive) | `248` | **H5** (≥0) → REJECT; **H6** (approved ≤ this, WARN) |
| 26 | `ApprovedQuantityPacks` | integer | Approved (additive) | `234` | **H5** (≥0) → REJECT; **H6** (≤ requested; received ≤ this, WARN) |
| 27 | `ReceivedQuantityPacks` | integer | Received (additive) | `231` | **H5** (≥0) → REJECT; **H6** (≤ approved, WARN) |
| 28 | `EmergencyRequestQuantityPacks` | integer | Emergency requests (additive) | `0` | **H5** (≥0) → REJECT |
| 29 | `OpeningStockPacks` | integer | Opening stock (**semi-additive**) | `467` | **H5** (≥0) → REJECT; **H7** (stock balance, WARN) |
| 30 | `DispensedQuantityPacks` | integer | Dispensed (additive) | `219` | **H5** (≥0) → REJECT; **H7** (WARN) |
| 31 | `ConsumedQuantityPacks` | integer | Consumed (additive) | `212` | **H5** (≥0) → REJECT |
| 32 | `WastageQuantityPacks` | integer | Wastage (additive) | `0` | **H5** (≥0) → REJECT; **H7** (WARN) |
| 33 | `ClosingStockPacks` | integer | Closing stock (**semi-additive**) | `479` | **H5** (≥0) → REJECT; **H7** (= open+recv−disp−waste, WARN) |
| 34 | `UnfulfilledDemandPacks` | integer | Unfulfilled demand (additive) | `0` | **H5** (≥0) → REJECT |
| 35 | `StockoutDays` | integer | Stock-out days in month | `0` | **H9** (0 … days in month) → REJECT |
| 36 | `ServiceLevelPct` | numeric (%) | Service level (non-additive) | `100` | **H8** (0 … 100) → REJECT |
| 37 | `MedicationRequestStatus` | text (enum) | Request status (junk dims removed; not carried to the mart) | `Completed` | — |
| 38 | `FormularyStatus` | text (enum) | Formulary status (junk dims removed; not carried to the mart) | `Formulary` | — |
| 39 | `AverageLeadTimeDays` | integer | Average lead time (non-additive) | `13` | — |
| 40 | `DemandTrendIndex` | numeric | Demand trend index (non-additive) | `1.221` | — |
| 41 | `SourceSystem` | text | Originating system | `HOSPITAL_ERP_FHIR_EXPORT` | — |

---

## 4. How these files were generated

**Method — bootstrap oversampling** (full notes:
[`docs/generator_method.md`](../docs/generator_method.md)). Rather than invent
values, the generator **resamples real history** into a new month, so seasonality
and the real per-medicine / channel / pharmacy / hospital mix are preserved and
referential integrity holds:

- **Period:** these archived files are the `2026-01` output. The demo has since loaded
  `2026-01` and `2026-02`, so the next live refresh is `2026-03`.
- **Sampling:** sales rows are reservoir-sampled from the same month-of-year in the
  real 05 file (bootstrap, with replacement); demand uses the complete
  hospital × medicine grain. Every amount, flag and attribute is copied **verbatim**
  from a real row.
- **What changes:** only identifiers and dates. New `SalesTransactionID` /
  `HospitalDemandRecordID` continue the ODS number sequence (no collisions);
  `SalesDate` is spread across the month; `BatchExpiryDate` is pushed into the
  future so nothing is sold expired.
- **Command (current generator):**
  `python generator/generate.py --period 2026-03 --bad-rows 5`.
  Every refresh also writes a fresh `01_master_data` and **deterministically flips the
  `PrescriptionClass` (Rx↔OTC) of 1–2 medicines** (seeded by the refresh month, logged to
  `meta.generation_log.presclass_changed`), which creates the SCD2 version. `--price-change N`
  is optional and now only changes prices, which are **Type 1** (no longer an SCD2 driver).

**Row counts** (from `meta.generation_log`, verified against the file line counts):

| Generated file | Rows generated | Bad rows | Date span |
| --- | ---: | ---: | --- |
| `05_pharmacy_sales_data__gen_2026-01` | 13,889 | 5 | 2026-01-01 → 2026-01-31 |
| `06_hospital_demand_data__gen_2026-01` | 756 | 0 | 2026-01-01 |
| `01_master_data__gen_2026-01` | 63 | 0 | — (master) |

**Bad rows injected** (`--bad-rows 5`) — five sales rows, each breaking exactly one
REJECT rule, to prove the validation layer quarantines them in `ods.rejected_rows`
(they never reach the mart):

| # | Field corrupted | Bad value | Rule broken |
| ---: | --- | --- | --- |
| 1 | `UnitRetailPriceUSD` | `-4.50` | **S6** (negative price) |
| 2 | `SalesDate` | `2026-13-40` | **S4** (invalid date) |
| 3 | `MedicineID` | *(empty)* | **S2** (missing MedicineID) |
| 4 | `PharmacyID` | *(empty)* | **S3** (missing pharmacy) |
| 5 | `QuantitySoldPacks` | `0` | **S7** (zero quantity) |

**SCD Type 2 via PresClass flip** — each refresh flips the `PrescriptionClass` of 1–2
medicines in the generated `01_master_data`. On the next transform this closes each
medicine's current `DimMedicine` version (`EffectiveTo` = the refresh month − 1 day,
`IsCurrent='N'`) and opens a new current version (`EffectiveFrom` = the first day of the
refresh month, `IsCurrent='Y'`), so the warehouse keeps full history and the refresh month's
sales of that medicine point to the new version.

**Net effect on the warehouse — verified from the `2026-02` refresh** (before → after the
chain ran, measured in testing):

| Table | Before | After | Δ |
| --- | ---: | ---: | ---: |
| `ods.pharmacy_sales` | 513,894 | 527,418 | +13,524 (13,519 good + 5 bad) |
| `ods.hospital_demand` | 27,972 | 28,728 | +756 |
| `FactPharmacySales` | 513,889 | 527,413 | +13,524 (5 bad rejected) |
| `FactHospitalDemand` | 27,972 | 28,728 | +756 |
| `DimMedicine` rows | 64 | 66 | +2 new SCD2 versions (MED022, MED001 flipped Rx→OTC) |
| `ods.rejected_rows` | — | — | +5 (rules S2, S3, S4, S6, S7) |

Row counts reconcile: ODS new rows = fact rows loaded + rejected rows, and the Postgres
`mart` matches the DuckDB `sdi` star exactly (10 tables, equal counts).
