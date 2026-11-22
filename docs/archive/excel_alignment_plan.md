# Excel-alignment plan — Phase 1 SDI mart

**Purpose.** Align the implemented Phase 1 SDI mart with the graded design workbook
(`docs/phase1_sdi_design.xlsx`). This document is an **analysis and change plan only** —
no pipeline code is changed in this step. It records (1) which files will change and why,
(2) every place the current table/column names are hard-coded, and (3) the results of
read-only data checks that confirm (or challenge) the target design.

Prepared: 2026-11-22. Branch: `main` (no new branch, no commit).

---

## 0. Target design vs. what is implemented today

| Area | Target (Excel) | Implemented today | Gap |
|---|---|---|---|
| Date dim | `DimDate` | `sdi.dim_date` | rename only |
| Medicine dim | `DimMedicine`, SCD2 on **PresClass + ProductStatus**, Type-1 otherwise | `sdi.dim_medicine`, SCD2 hash over price/cost + ProductStatus + PrescriptionClass + ColdChainFlag + storage temps/humidity | **narrow the SCD2 trigger set** to PresClass + ProductStatus |
| Pharmacy dim | `DimPharmacy`, SCD1, **includes SalesChannel** | `sdi.dim_pharmacy`, SCD1, no channel | add SalesChannel — **see risk R1** |
| Hospital dim | `DimHospital`, SCD1 | `sdi.dim_hospital`, SCD1 | rename only |
| Location dim | `DimLocation`, natural key **City+State**, shared by pharmacy & hospital | *(none — city/state are columns on dim_pharmacy and dim_hospital)* | **new conformed dimension** + two FKs |
| Sales fact | `FactPharmacySales`, 1 row per `SalesTransactionID` | `sdi.fact_sales`, 1 row per `sales_transaction_id` | rename; **drop role-playing dates**; swap channel/junk FKs |
| Demand fact | `FactHospitalDemand`, hospital × medicine × month | `sdi.fact_hospital_demand` | rename; drop junk FK |
| `dim_channel` | **removed** | present (static RETAIL/HOSPITAL/ECOM) | remove — channel becomes an attribute |
| `dim_sales_profile` (junk) | **removed** | present (9-flag junk) | remove — flags move onto the fact (degenerate) or are dropped |
| `dim_demand_status` (junk) | **removed** | present (2×3 junk) | remove — status columns move onto the fact |
| Extra sales dates | **removed** | `pharmacy_delivery_date_key`, `batch_expiry_date_key` role-play `dim_date` | drop the two extra date FKs |

> This plan assumes a **rename + restructure**, not a parallel rebuild. Every rename below
> is `snake_case → PascalCase` (`dim_date → DimDate`, `fact_sales → FactPharmacySales`, …).
> If the team prefers to keep `snake_case` physical names and treat the Excel names as logical,
> then Section 2 shrinks to only the *structural* changes (channel/junk/location/date-roles)
> and the pure renames can be skipped. **Confirm this naming decision before implementing.**

---

## 1. Files that will change (and why), and files that will NOT change

### 1a. Schema / DDL

| File | Change | Why |
|---|---|---|
| `sql/mart/sdi_01_create_schema.sql` | Rename all 7 dims + 2 facts to Excel names; **delete** `dim_channel`, `dim_sales_profile`, `dim_demand_status`; **add** `DimLocation` (surrogate key + City/State natural key + `-1` member); add `location_key` to `DimPharmacy`/`DimHospital` (or keep city/state there too — decide); remove `pharmacy_delivery_date_key` and `batch_expiry_date_key` from the sales fact; replace `channel_key`/`sales_profile_key` FKs with a `sales_channel` column + degenerate flag columns; remove `demand_status_key` FK from the demand fact, move `medication_request_status`/`formulary_status` onto it as columns | Core structural target of the workbook |

### 1b. Transform SQL

| File | Change | Why |
|---|---|---|
| `sql/mart/sdi_10_validate.sql` | Keep the REJECT/WARN rule logic, but: stop deriving `channel_code` (lines ~197–199) if channel is no longer a dim; keep deriving `sales_channel` straight from the source; stop building the junk-combo columns used only by `dim_sales_profile`/`dim_demand_status`; produce `City`/`State` for the new `DimLocation`; recompute the SCD2 hash (line ~77–79) over **only** PresClass + ProductStatus | Clean-staging columns must match the new dims/facts |
| `sql/mart/sdi_20_dims.sql` | Remove the `dim_sales_profile` and `dim_demand_status` inserts (lines 126–145); add a `DimLocation` upsert (distinct City+State from sales **and** demand); add SalesChannel to the `dim_pharmacy` upsert; resolve `location_key` for pharmacy/hospital; narrow the SCD2 compare to the new hash | Loads the restructured dims |
| `sql/mart/sdi_30_facts.sql` | Drop the `dim_channel` join (line 46) and `dim_sales_profile` join (lines 47–56); write `sales_channel` + degenerate flags directly; drop `pharmacy_delivery_date_key`/`batch_expiry_date_key` resolution (lines 40–41); drop the `dim_demand_status` join (lines 86–88) and write the status columns directly | Facts must match the new grain/columns |
| `sql/mart/sdi_40_tests.sql` | Remove FK-in-dim checks for `dim_channel`/`dim_sales_profile`/`dim_demand_status` (lines 48–49, 56); rename fact/dim references; add FK-in-dim check for `DimLocation` | Tests must reference existing objects |
| `sql/mart/sdi_50_aggregates.sql` | `agg_sales_month_channel` now groups by `FactPharmacySales.sales_channel` (or `DimPharmacy.sales_channel`) instead of joining `dim_channel`; rename fact/dim references in all three agg tables | Agg layer feeds the widgets |

### 1c. Query layer (dashboard widgets)

| File | Change | Why |
|---|---|---|
| `sql/queries/q01_channel_revenue_margin.sql` | Replace `JOIN sdi.dim_channel` with a group-by on `sales_channel` | channel is no longer a dim |
| `sql/queries/q01_channel_revenue_margin_opt.sql` | Point at the reshaped `agg_sales_month_channel` | same |
| `sql/queries/q02_hospital_forecast_vs_actual{,_opt}.sql` | Rename `fact_hospital_demand`/agg table | rename only |
| `sql/queries/q03_top10_fast_slow_movers{,_opt}.sql` | Rename `fact_sales`/`agg_sales_medicine_month` | rename only |
| `sql/queries/q04…q06_*{,_opt}.sql` | Rename `fact_sales` / `agg_sales_month_channel` | rename only |

### 1d. DAGs

| File | Change | Why |
|---|---|---|
| `dags/sdi_transform.py` | Lines 174, 176, 178: `mart.fact_sales` / `mart.fact_hospital_demand` → `mart.FactPharmacySales` / `mart.FactHospitalDemand`; comment at line 18 | Row-count notes query the renamed mart tables |
| `dags/sdi_generate.py`, `dags/sdi_ingest.py`, `dags/sdi_query.py`, `dags/sdi_storage_metrics.py` | **No table-name changes** unless they embed mart names (none found); verify only | They operate on ODS / `sql/queries` / `meta`, not mart DDL |

### 1e. Serving / query runner / storage metrics

| File | Change | Why |
|---|---|---|
| `serving/publish_mart.py` | **No change** — it copies *every* table in DuckDB schema `sdi` generically; it never hard-codes a table name. Renamed tables publish automatically | generic by design |
| `query/query_runner.py` | Line 149 hard-codes `sdi.fact_sales` in the deliberate "error" benchmark query → rename to `FactPharmacySales`; otherwise it reads `sql/queries/*.sql` generically | one literal reference |
| `ingestion/storage_metrics.py` | Lines 45, 66, 68, 70, 72, 80, 83, 85, 88: table names in `_domain_for` and the date-coverage queries → rename; drop `dim_channel`/`dim_sales_profile` from the "sales" domain test, add `DimLocation` | storage census keys on explicit names |

### 1f. Grafana

| File | Change | Why |
|---|---|---|
| `bi/grafana/dashboards/*.json` (all 4) | **No change** — grep confirms none reference mart tables; they query `meta.*` only (`batch_log`, `dq_log`, `query_log`, `storage_snapshot`, `pipeline_run`, `generation_log`) | decoupled from the mart |
| `bi/grafana/provisioning/**`, import/export scripts | **No change** | datasource/provisioning only |

### 1g. Power BI

| File | Change | Why |
|---|---|---|
| `bi/powerbi/sdi_business.pbix` | Will need re-pointing to renamed `mart.*` tables + the new channel/location model (binary; out of scope to edit here — flag for the BI owner) | reads `mart.*` |

### 1h. Tests / assumption checks

| File | Change | Why |
|---|---|---|
| `ingestion/check_phase1_assumptions.py`, `ingestion/profile_sources.py` | Verify only — they profile **ODS/source**, not the mart; no rename needed unless they assert on channel/junk design | source-side |
| `sql/mart/sdi_40_tests.sql` | (covered in 1b) | |

### 1i. Docs

| File | Change | Why |
|---|---|---|
| `docs/phase1_sdi_design.md` | Rewrite the star-schema section (lines ~95–146): drop `dim_channel`/`dim_sales_profile`/`dim_demand_status` and the role-playing extra dates from the Mermaid ER + tables; add `DimLocation`; narrow the SCD2 trigger description | design doc must match the Excel |
| `docs/build_design_xlsx.py` | Lines 85, 125–126, 131–139, 147–148, 169–205, 257–328: this script **generates** the Excel; the Excel is now the source of truth. Either retire the script or rewrite it to emit the new model | avoid drift between generator and workbook |
| `docs/data_profiling_report.md`, `docs/phase1_assumption_checks.md`, `docs/generator_method.md`, `docs/milestone1_demo_script.md`, `oversampled_data/data_dictionary.md` | Update table-name references (e.g. demo script lines 30–31, data dictionary line 84 maps `SalesChannel → dim_channel`) | narrative/demo consistency |
| `README.md` | Architecture blurb says "two fact tables, conformed and SCD2 dims, **junk and degenerate** dims" (lines 13–14) — update once junk dims are removed | top-level accuracy |

### Files that will **NOT** change
- `serving/publish_mart.py` (generic copy loop)
- `bi/grafana/dashboards/*.json`, all Grafana provisioning/scripts (query `meta.*` only)
- `sql/postgres/*` ODS/meta DDL (ODS stays raw-text; the restructure is downstream of ODS)
- `generator/generate.py`, `dags/sdi_generate.py`, `dags/sdi_ingest.py` (source/ingest side)
- `ingestion/file_watcher.py`, `ingestion/seed_landing.py`, `ingestion/ingest_api.py`
- `dags/sdi_query.py`, `dags/sdi_storage_metrics.py` (orchestration, no embedded mart names — verify)
- `transform/transform_lib.py` (runs SQL files by path; no table names embedded — verify)

---

## 2. Hard-coded table/column-name inventory (file:line)

Current objects being removed/renamed: `fact_sales`, `fact_hospital_demand`,
`dim_channel`, `dim_sales_profile`, `dim_demand_status`,
`agg_sales_month_channel`, `agg_demand_month_hospital`, `agg_sales_medicine_month`.

### `fact_sales` → `FactPharmacySales`
- `sql/mart/sdi_01_create_schema.sql:247` (CREATE), `:238`, `:143`, `:14`, `:27`, `:195` (comments)
- `sql/mart/sdi_10_validate.sql:143`, `:150`
- `sql/mart/sdi_30_facts.sql:15`, `:17`
- `sql/mart/sdi_40_tests.sql:18`, `:21`, `:30`, `:31`, `:43`, `:44`, `:63`, `:66`
- `sql/mart/sdi_50_aggregates.sql:13`, `:34`, `:72`
- `sql/queries/q01_channel_revenue_margin.sql:2`, `:9`
- `sql/queries/q03_top10_fast_slow_movers.sql:6`
- `sql/queries/q04_kpi_total_revenue.sql:1`, `:4`, `:8`
- `sql/queries/q05_kpi_total_units.sql:1`, `:4`, `:8`
- `sql/queries/q06_kpi_margin_pct.sql:1`, `:4`, `:8`
- `query/query_runner.py:149`
- `ingestion/storage_metrics.py:66`, `:68`, `:80`, `:83`
- `dags/sdi_transform.py:18`, `:174`, `:178` (`mart.fact_sales`)
- Docs: `docs/build_design_xlsx.py:85,125,131,147,169,180,186,257,259,298,299,301–309,328`; `docs/phase1_sdi_design.md:32,61,101–106,116,124`; `docs/milestone1_demo_script.md:30,35,78`; `docs/generator_method.md:72`; `oversampled_data/data_dictionary.md:75,234`

### `fact_hospital_demand` → `FactHospitalDemand`
- `sql/mart/sdi_01_create_schema.sql:295`, `:285`, `:15`, `:28`
- `sql/mart/sdi_10_validate.sql:287`, `:294`
- `sql/mart/sdi_30_facts.sql:60`, `:62`
- `sql/mart/sdi_40_tests.sql:23`, `:26`, `:36`, `:37`, `:52`, `:53`, `:71`, `:74`
- `sql/mart/sdi_50_aggregates.sql:57`
- `sql/queries/q02_hospital_forecast_vs_actual.sql:2`, `:9`
- `ingestion/storage_metrics.py:70`, `:72`, `:85`, `:88`
- `dags/sdi_transform.py:18`, `:176`, `:178` (`mart.fact_hospital_demand`)
- Docs: `docs/build_design_xlsx.py:85,126,132,148,180,260,262,300,310–314`; `docs/phase1_sdi_design.md:107–110,117,128`; `docs/milestone1_demo_script.md:31`; `docs/generator_method.md:73`; `oversampled_data/data_dictionary.md:132,235`

### `dim_channel` → **removed** (channel becomes an attribute)
- `sql/mart/sdi_01_create_schema.sql:179` (CREATE), `:186` (seed INSERT), `:11`, `:143`, `:173` (comments)
- `sql/mart/sdi_20_dims.sql:4` (comment — "already populated")
- `sql/mart/sdi_30_facts.sql:46` (JOIN)
- `sql/mart/sdi_40_tests.sql:48` (FK check)
- `sql/mart/sdi_50_aggregates.sql:36` (JOIN)
- `sql/queries/q01_channel_revenue_margin.sql:11` (JOIN)
- `ingestion/storage_metrics.py:45` (domain tag)
- Docs: `docs/build_design_xlsx.py:85,125,138,187,199,205`; `docs/phase1_sdi_design.md:105,128`; `oversampled_data/data_dictionary.md:84`

### `dim_sales_profile` → **removed** (flags become degenerate fact columns)
- `sql/mart/sdi_01_create_schema.sql:201` (CREATE), `:218` (seed), `:12`, `:194` (comments)
- `sql/mart/sdi_20_dims.sql:129` (INSERT), `:13`, `:127` (comments)
- `sql/mart/sdi_30_facts.sql:47` (JOIN, lines 47–56)
- `sql/mart/sdi_40_tests.sql:49` (FK check)
- `ingestion/storage_metrics.py:45` (domain tag)
- Docs: `docs/build_design_xlsx.py:85,125,139,189,190,200,205`; `docs/phase1_sdi_design.md:106,129`

### `dim_demand_status` → **removed** (status becomes fact columns)
- `sql/mart/sdi_01_create_schema.sql:227` (CREATE), `:234` (seed), `:223` (comment)
- `sql/mart/sdi_20_dims.sql:142` (INSERT), `:14`, `:140` (comments)
- `sql/mart/sdi_30_facts.sql:86` (JOIN, lines 86–88)
- `sql/mart/sdi_40_tests.sql:56` (FK check)
- Docs: `docs/build_design_xlsx.py:85,126,139,191,201,205`; `docs/phase1_sdi_design.md:110,130`

### `agg_*` tables (rename / reshape; no FK changes but channel source changes)
- `agg_sales_month_channel`: `sql/mart/sdi_50_aggregates.sql:19`; `sql/queries/q01_…_opt.sql:7`; `q04_…_opt.sql:2,5`; `q05_…_opt.sql:2,5`; `q06_…_opt.sql:2,5`
- `agg_demand_month_hospital`: `sql/mart/sdi_50_aggregates.sql:41`; `sql/queries/q02_…_opt.sql:7`
- `agg_sales_medicine_month`: `sql/mart/sdi_50_aggregates.sql:64`; `sql/queries/q03_…_opt.sql:7`

> Note: `serving/publish_mart.py` and the Grafana JSON contain **zero** hard-coded references
> to any of the above — confirmed by grep. They adapt automatically.

---

## 3. Read-only data checks on ODS (results)

Run 2026-11-22 against Postgres `ida_staging` (`ida_user`). ODS now holds the base load
**plus** a `2026-01` refresh, so counts exceed the original profiling numbers
(`pharmacy_sales` = 513,894; `hospital_demand` = 27,972; `master_data` = 126 = 63 medicines × 2 monthly snapshots).

### (a) Exact ODS column names

**01 `ods.master_data` (33 source cols):** MedicineID, InternalSKU, GTIN14, GenericName,
FictionalBrandName, DiseaseCategory, ICD10Category, ATCCode, TherapeuticClass, DosageForm,
Strength, RouteOfAdministration, PackSize, BaseUnitOfMeasure, PrescriptionClass,
ControlledMedicineFlag, ColdChainFlag, StorageMinTempC, StorageMaxTempC, MaxHumidityPct,
ShelfLifeMonths, MinimumRemainingShelfLifeDays, PrimarySupplierID, PrimaryPlantID,
ManufacturingLeadTimeDays, StandardBatchSizePacks, SafetyStockDays, ReorderReviewCycleDays,
UnitManufacturingCostUSD, WholesalePriceUSD, RecommendedRetailPriceUSD, ProductStatus,
EffectiveFromDate, SourceSystem.

**05 `ods.pharmacy_sales` (45 source cols):** SalesTransactionID, SalesDate, SalesTimestampUTC,
**SalesChannel**, PharmacyID, PharmacyGLN, PharmacyName, PharmacyType, HospitalID,
**PharmacyCity, PharmacyState**, CountryCode, PharmacyOrderID, PharmacyDeliveryID,
PharmacyDeliveryDate, DeliveryQuantityPacks, DeliveryOTIFFlag, WarehouseLotID,
SourceWarehouseID, ProductionBatchID, MedicineID, GTIN14, DiseaseCategory, GenericName,
BatchExpiryDate, DaysToExpiryAtSale, QuantitySoldPacks, UnitRetailPriceUSD,
GrossSalesAmountUSD, DiscountAmountUSD, NetSalesAmountUSD, SalesTaxUSD, CostOfGoodsSoldUSD,
GrossMarginUSD, PromotionCode, PrescriptionRequiredFlag, PrescriptionID, CustomerSegment,
PayerType, PaymentMethod, EcommerceDeliveryStatus, ReturnFlag, ReturnedQuantityPacks,
SaleStatus, SourceSystem.

**06 `ods.hospital_demand` (41 source cols):** HospitalDemandRecordID, DemandMonth, HospitalID,
HospitalGLN, HospitalName, HospitalType, HospitalPharmacyID, **City, State**, CountryCode,
LicensedBeds, ICUBeds, AverageOccupancyRatePct, TraumaLevel, CatchmentPopulation, MedicineID,
GTIN14, GenericName, DiseaseCategory, ICD10Category, EstimatedDiseaseCases,
DiseaseRelatedAdmissions, OutpatientEncounters, ForecastDemandPacks, RequestedQuantityPacks,
ApprovedQuantityPacks, ReceivedQuantityPacks, EmergencyRequestQuantityPacks, OpeningStockPacks,
DispensedQuantityPacks, ConsumedQuantityPacks, WastageQuantityPacks, ClosingStockPacks,
UnfulfilledDemandPacks, StockoutDays, ServiceLevelPct, MedicationRequestStatus, FormularyStatus,
AverageLeadTimeDays, DemandTrendIndex, SourceSystem.

### (b) Does any PharmacyID appear with more than one SalesChannel? **YES — 48 pharmacies.**
Every one of the 48 mixes exactly `Ecommerce` and `Physical Pharmacy`.
Examples: `PHR013`, `PHR014`, `PHR015`, `PHR016`, `PHR017` (each → `Ecommerce | Physical Pharmacy`).
→ **SalesChannel is a transaction-level fact, not a stable pharmacy attribute.** See **risk R1**.

### (c) Distinct SalesChannel values with counts
| SalesChannel | rows |
|---|---|
| Physical Pharmacy | 425,761 |
| Ecommerce | 88,133 |

Only two source values (**not** the RETAIL/HOSPITAL/ECOM triple the current `dim_channel` seeds —
today's `channel_code` is *derived*: `Ecommerce→ECOM`, else `Hospital Pharmacy→HOSPITAL`, else `RETAIL`).

### (d) MedicineID → InternalSKU, and GTIN14 join 06↔01
- **MedicineID ↔ InternalSKU is strictly 1-to-1.** 63 distinct MedicineIDs, 63 distinct InternalSKUs;
  0 MedicineIDs map to >1 SKU; 0 SKUs map to >1 MedicineID. (126 master rows = 2 monthly snapshots of 63.)
- **`lpad(GTIN14,14,'0')` in 06 matches 01 for every row:** 55,944 / 55,944 match, 0 mismatched,
  0 MedicineIDs missing from 01. GTIN14 is a safe conformed attribute of DimMedicine.

### (e) Distinct values / ranges
- **DosageForm — 13:** Tablet (70), Capsule (16), Gastro-resistant tablet (10), Dry-powder inhaler (6),
  Gastro-resistant capsule (4), Metered-dose inhaler (4), Solution for injection (4), Effervescent tablet (2),
  Inhalation capsule (2), Modified-release tablet (2), Nebulizer solution (2), Oral solution (2), Pre-filled pen (2).
- **RouteOfAdministration — 3:** Oral (106), Inhalation (14), Subcutaneous (6).
- **PharmacyType — 3:** Chain Pharmacy (228,327), Independent Pharmacy (173,339), Hospital Pharmacy (112,228).
- **ShelfLifeMonths — 2:** 24, 36.
- **PackSize — min 1, max 100** (13 distinct values).
- **CountryCode — 1:** `US` only, in both 05 and 06. (A single-country column — low analytic value; keep on DimLocation or drop.)

### (f) Date coverage
- **05 SalesDate:** min `2023-01-30`, max `2026-01-31`.
- **06 DemandMonth:** min `2023-01-01`, max `2026-01-01` (always 1st of month).
→ Data now runs to **2026-01** (a refresh beyond the 2023–2025 window in the design doc).
`dim_date`/`DimDate` already covers 2022–2029, so no date-dim change is needed.

### (g) City/State presence and shared locations
- **05 has `PharmacyCity` + `PharmacyState`; 06 has `City` + `State`** — both present (different column names).
- **Distinct City+State pairs: 18 across both** (union). Sales = 18 pairs, demand = 12 pairs, **12 in both**.
  Every demand location is also a pharmacy location → the 12 hospital locations are a subset of the 18.
→ **`DimLocation` is viable with 18 members**, conformed across pharmacy and hospital, natural key = City+State.
  Mind the column-name mismatch when unioning (`PharmacyCity/PharmacyState` vs `City/State`).

### (h) Do ICUBeds / LicensedBeds / AverageOccupancyRatePct vary within a hospital-month (across medicines)?
- **No.** Across 444 hospital-month groups, **0** vary in LicensedBeds, ICUBeds, or AverageOccupancyRatePct.
- Stronger: across all months per hospital (12 hospitals), **0** vary over time either.
→ All three are **stable hospital attributes** — correctly placed on `DimHospital` (SCD1); they are not
  monthly measures and do not belong on the demand fact.

---

## 4. Open decisions & risks (raised, not resolved — no code changed)

- **R1 — SalesChannel on DimPharmacy is unsafe (from check b/c).** The Excel puts SalesChannel on
  `DimPharmacy` (SCD1), but 48 pharmacies sell through **both** Ecommerce and Physical Pharmacy, and the
  split is material (88,133 Ecommerce rows). A single SCD1 value per pharmacy would **misattribute** every
  transaction on the pharmacy's other channel, breaking the channel-revenue widget (q01 / `agg_sales_month_channel`).
  **Recommendation:** keep `SalesChannel` at **transaction grain** — as a degenerate attribute on
  `FactPharmacySales` (and group the channel widget on it). If the workbook must be followed literally,
  flag this to the grader as a known data/design conflict. **Decision needed.**
- **R2 — Naming convention.** Pure `snake_case → PascalCase` renames are ~70% of Section 2. Confirm whether
  the physical DuckDB/Postgres names must become PascalCase, or whether the Excel names are logical only
  (which removes most of the churn and all the quoting headaches in DuckDB/Postgres).
- **R3 — Removing the junk dimensions** moves 9 sales flags + 2 demand status columns onto the facts as
  degenerate columns. Decide which flags are kept (analytically used: ReturnFlag, PrescriptionRequiredFlag,
  CustomerSegment, PayerType, SaleStatus) vs dropped. This widens the facts but matches the Excel.
- **R4 — SCD2 trigger narrowing.** Today a new `dim_medicine` version is cut when **any** of price/cost,
  ProductStatus, PrescriptionClass, ColdChainFlag, or storage temps/humidity changes. The Excel tracks
  **only PresClass + ProductStatus**. Narrowing means price changes become **Type-1 overwrites** and stop
  creating history — this directly changes the refresh demo ("refresh changed N medicines' price → new SCD2
  versions"). Confirm the grader wants price treated as Type-1.
- **R5 — CountryCode** is constant `US`; `DeliveryQuantityPacks`, role-playing delivery/expiry dates, and the
  `-1`/Unknown members are all candidates to revisit while restructuring. Out of scope for this step.

---

*End of plan. No pipeline code was modified; checks above were read-only `SELECT`s.*
