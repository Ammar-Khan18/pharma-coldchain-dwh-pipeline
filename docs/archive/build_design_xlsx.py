"""
RETIRED — DO NOT RUN. (moved to docs/archive/ on 2026-11-22)

The hand-edited Milestone 1 workbook docs/phase1_sdi_design.xlsx is now the
SOURCE OF TRUTH for the design and must not be overwritten. This script would
rebuild that .xlsx from the (older, pre-Excel) lowercase model and clobber the
hand edits, so it is kept only for reference and is no longer part of the
pipeline. The living text design is docs/phase1_sdi_design.md.

----------------------------------------------------------------------------
build_design_xlsx.py  —  (originally) regenerate docs/phase1_sdi_design.xlsx.

Reads the dimensional model's column names and types LIVE from the DuckDB sdi
schema and the latest validation counts from meta.dq_log. NOTE: it predates the
Excel-aligned PascalCase model, so its table/column lists are out of date.
"""
import os
import duckdb, psycopg2
from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

REPO = Path(__file__).resolve().parents[1]
DUCK = Path(os.environ.get("DUCKDB_DIR", str(REPO / "marts"))) / "sdi_mart.duckdb"
OUT = REPO / "docs" / "phase1_sdi_design.xlsx"
DSN = os.environ.get("IDA_PG_DSN",
                     "host=localhost port=5432 dbname=ida_staging user=ida_user password=ida_pass")

# ---- styles ----------------------------------------------------------------
NAVY = "1F4E78"; BLUE = "2E75B6"; LIGHT = "D9E1F2"; GREEN = "C6E0B4"; GREY = "F2F2F2"
WHITE = Font(color="FFFFFF", bold=True)
BOLD = Font(bold=True)
TITLE_FONT = Font(color="FFFFFF", bold=True, size=14)
thin = Side(style="thin", color="BFBFBF")
BORDER = Border(left=thin, right=thin, top=thin, bottom=thin)
WRAP = Alignment(wrap_text=True, vertical="top")
CENTER = Alignment(horizontal="center", vertical="center")
fill = lambda c: PatternFill("solid", fgColor=c)


def title(ws, text, ncols, row=1):
    ws.merge_cells(start_row=row, start_column=1, end_row=row, end_column=ncols)
    c = ws.cell(row=row, column=1, value=text)
    c.fill = fill(BLUE); c.font = TITLE_FONT; c.alignment = Alignment(vertical="center", indent=1)
    ws.row_dimensions[row].height = 26


def header(ws, row, headers):
    for j, h in enumerate(headers, 1):
        c = ws.cell(row=row, column=j, value=h)
        c.fill = fill(NAVY); c.font = WHITE; c.border = BORDER
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    ws.row_dimensions[row].height = 28


def rows_out(ws, start, data, wrap_cols=(), zebra=True):
    r = start
    for i, row in enumerate(data):
        for j, val in enumerate(row, 1):
            c = ws.cell(row=r, column=j, value=val)
            c.border = BORDER
            c.alignment = WRAP if (j - 1) in wrap_cols else Alignment(vertical="top")
            if zebra and i % 2: c.fill = fill(GREY)
        r += 1
    return r


def widths(ws, w):
    for i, width in enumerate(w, 1):
        ws.column_dimensions[get_column_letter(i)].width = width


def label_block(ws, row, label, value, ncols=1, value_span=1):
    c = ws.cell(row=row, column=1, value=label); c.fill = fill(LIGHT); c.font = BOLD
    c.border = BORDER; c.alignment = Alignment(vertical="top")
    if value_span > 1:
        ws.merge_cells(start_row=row, start_column=2, end_row=row, end_column=1 + value_span)
    v = ws.cell(row=row, column=2, value=value); v.alignment = WRAP; v.border = BORDER
    return row + 1


# ---- load live schema + dq counts -----------------------------------------
d = duckdb.connect(str(DUCK), read_only=True)
def cols(t):
    return d.execute("SELECT column_name, data_type FROM information_schema.columns "
                     "WHERE table_schema='sdi' AND table_name=? ORDER BY ordinal_position", [t]).fetchall()
SCHEMA = {t: cols(t) for t in ["dim_date","dim_medicine","dim_pharmacy","dim_hospital",
          "dim_channel","dim_sales_profile","dim_demand_status","fact_sales","fact_hospital_demand"]}
d.close()

pg = psycopg2.connect(DSN); cur = pg.cursor()
cur.execute("SELECT etl_batch_id FROM meta.dq_log GROUP BY etl_batch_id "
            "HAVING sum(rows_checked) > 10000 ORDER BY max(logged_at) DESC LIMIT 1")
row = cur.fetchone(); DQ_BATCH = row[0] if row else None
DQ = {}
if DQ_BATCH:
    cur.execute("SELECT rule_id, sum(rows_checked), sum(rows_failed) FROM meta.dq_log "
                "WHERE etl_batch_id=%s GROUP BY rule_id", (DQ_BATCH,))
    for rid, chk, fail in cur.fetchall():
        DQ[rid] = (int(chk or 0), int(fail or 0))
pg.close()

wb = Workbook(); wb.remove(wb.active)

# ===================== 1. OVERVIEW =====================
ws = wb.create_sheet("Overview")
title(ws, "Phase 1 — Sales & Demand Intelligence (SDI) mart", 2)
r = 3
r = label_block(ws, r, "Mart name", "sdi  (DuckDB star schema in marts/sdi_mart.duckdb; published to Postgres schema 'mart' for Power BI)")
r = label_block(ws, r, "OLAP engine", "DuckDB (transform + query). Serving copy in PostgreSQL. Orchestrated by Apache Airflow.")
r = label_block(ws, r, "Design basis", "docs/phase1_sdi_design.md + sql/mart/sdi_01_create_schema.sql; column types read live from the DuckDB sdi schema.")
r += 1
c = ws.cell(row=r, column=1, value="Business questions the mart answers"); c.font = WHITE; c.fill = fill(NAVY); c.border = BORDER
ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=2); r += 1
for q in [
    "Revenue, cost, gross margin and margin % by channel (Retail / Hospital / E-commerce) by month.",
    "Hospital forecast vs actual consumption, and where demand is unfulfilled, by hospital by month.",
    "Top 10 fast-moving and top 10 slow-moving medicines by therapeutic class (units sold).",
    "KPI cards: total revenue, units sold and margin % for the latest month.",
    "Pipeline observability: batch ingestion, storage share, query performance, data quality (Grafana).",
]:
    cc = ws.cell(row=r, column=1, value="•  " + q); cc.alignment = WRAP; cc.border = BORDER
    ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=2); r += 1
r += 1
header(ws, r, ["Source file", "Rows", "Description"]); r += 1
r = rows_out(ws, r, [
    ["01_master_data.csv", 63, "Medicine master — one row per medicine (MedicineID). Feeds dim_medicine."],
    ["05_pharmacy_sales_data.csv", 500000, "Pharmacy sales transactions. Feeds fact_sales, dim_pharmacy, dim_channel, dim_sales_profile."],
    ["06_hospital_demand_data.csv", 27216, "Hospital monthly demand (12 hospitals × 63 medicines × 36 months). Feeds fact_hospital_demand, dim_hospital, dim_demand_status."],
], wrap_cols=(2,))
r += 1
header(ws, r, ["Fact table", "Fact type", "Grain"]); r += 1
rows_out(ws, r, [
    ["fact_sales", "Transaction", "One pharmacy sales transaction (one row of 05)."],
    ["fact_hospital_demand", "Periodic snapshot (monthly)", "One hospital × medicine × month (one row of 06)."],
], wrap_cols=(2,))
widths(ws, [34, 12, 92]); ws.freeze_panes = "A3"

# ===================== 2. BUS MATRIX =====================
ws = wb.create_sheet("Bus Matrix")
dims = ["dim_date", "dim_medicine", "dim_hospital", "dim_pharmacy", "dim_channel",
        "dim_sales_profile", "dim_demand_status"]
conformed = {"dim_date", "dim_medicine"}
title(ws, "Bus matrix — business processes × dimensions (✔ = used; green = conformed, reused by Phases 2–3)", len(dims) + 1)
header(ws, 2, ["Business process"] + dims)
for j, dname in enumerate(dims, 2):
    if dname in conformed:
        ws.cell(row=2, column=j).fill = fill("548235")
matrix = [
    ("Phase 1 — Sales (fact_sales)",            ["✔","✔","✔","✔","✔","✔",""]),
    ("Phase 1 — Hospital demand (fact_hospital_demand)", ["✔","✔","✔","","","","✔"]),
    ("Phase 2 — Inventory (future)",            ["✔","✔","","","","",""]),
    ("Phase 3 — Cold chain (future)",           ["✔","✔","","","","",""]),
]
r = 3
for name, marks in matrix:
    future = name.startswith("Phase 2") or name.startswith("Phase 3")
    c = ws.cell(row=r, column=1, value=name); c.font = BOLD; c.border = BORDER
    c.alignment = Alignment(vertical="center")
    if future: c.fill = fill(GREY)
    for j, m in enumerate(marks, 2):
        cc = ws.cell(row=r, column=j, value=m); cc.border = BORDER; cc.alignment = CENTER
        if dims[j-2] in conformed and m == "✔":
            cc.fill = fill(GREEN)
        elif future:
            cc.fill = fill(GREY)
    ws.row_dimensions[r].height = 22
    r += 1
r += 1
note = ("dim_date and dim_medicine are CONFORMED dimensions (green): identical keys and attributes are reused "
        "by Phases 2–3, so facts across phases join to the same dimensions (a fact constellation). "
        "dim_date is also ROLE-PLAYING in fact_sales (sale date, pharmacy delivery date, batch expiry date). "
        "Degenerate dimensions (transaction / order / delivery / prescription / batch / lot IDs) live on the "
        "fact rows themselves and are not shown as columns here.")
ws.merge_cells(start_row=r, start_column=1, end_row=r + 3, end_column=len(dims) + 1)
cc = ws.cell(row=r, column=1, value=note); cc.alignment = WRAP; cc.fill = fill(LIGHT); cc.border = BORDER
widths(ws, [42] + [15] * len(dims)); ws.freeze_panes = "B3"

# ===================== 3. DIMENSIONS =====================
ws = wb.create_sheet("Dimensions")
DIM_META = {
 "dim_date": ("Conformed, role-playing", "date_key (yyyymmdd)", "the calendar date / month",
              "Static calendar 2022–2029; member -1 = Unknown. Reused as 3 roles in fact_sales and as the month in fact_hospital_demand."),
 "dim_medicine": ("Conformed, SCD Type 2", "medicine_key (sequence)", "medicine_id (e.g. MED001)",
              "Type-2 on price/cost, product_status, prescription_class, cold_chain_flag, storage limits (new row, history kept via valid_from/valid_to/is_current, hashed in scd2_hash). Names/descriptive = Type 1 (overwrite). Member -1 = Unknown."),
 "dim_pharmacy": ("SCD Type 1", "pharmacy_key (sequence)", "pharmacy_id (e.g. PHR001)",
              "Built from distinct pharmacies in 05; attributes overwritten in place. Member -1 = Unknown."),
 "dim_hospital": ("SCD Type 1", "hospital_key (sequence)", "hospital_id (e.g. HOSP001)",
              "Built from distinct hospitals in 06; bed_size_band derived. Member -1 = 'Not a hospital sale' (used by retail/e-commerce fact_sales rows)."),
 "dim_channel": ("Static / derived", "channel_key (fixed 1/2/3)", "channel_code (RETAIL/HOSPITAL/ECOM)",
              "Derived from SalesChannel + PharmacyType. Fixed 3 members + -1 Unknown."),
 "dim_sales_profile": ("Junk dimension", "sales_profile_key (sequence)", "the 9-flag combination",
              "Bundles 9 low-cardinality sales flags into one narrow table (one row per observed combination). Keeps fact_sales narrow. Member -1 = Unknown."),
 "dim_demand_status": ("Junk dimension", "demand_status_key (sequence)", "(request status × formulary status)",
              "Bundles the two low-cardinality demand status flags. Member -1 = Unknown."),
}
DESC = {
 "dim_date": {"date_key":"Surrogate key, yyyymmdd integer (-1 = Unknown)","full_date":"The calendar date","day_of_month":"Day number 1–31","day_of_week_num":"1=Mon … 7=Sun","day_name":"Weekday name","is_weekend":"True for Sat/Sun","iso_week":"ISO week number","month_num":"Month 1–12","month_name":"Month name","month_short":"3-letter month","year_month":"'YYYY-MM'","month_start_date":"First day of the month","quarter_num":"Quarter 1–4","year_quarter":"'YYYY-Qn'","year_num":"Year"},
 "dim_medicine": {"medicine_key":"Surrogate key (-1 = Unknown)","medicine_id":"Natural key (MedicineID)","internal_sku":"Internal SKU (Type 1)","gtin14":"GTIN-14, zero-padded to 14 digits","generic_name":"Generic name (Type 1)","brand_name":"Fictional brand name (Type 1)","disease_category":"Disease category","icd10_category":"ICD-10 category","atc_code":"ATC code","therapeutic_class":"Therapeutic class","dosage_form":"Dosage form","strength":"Strength","route_of_administration":"Route of administration","pack_size":"Units per pack","base_unit_of_measure":"Base unit (pack/device)","prescription_class":"Prescription / OTC (Type 2)","controlled_medicine_flag":"Controlled Y/N","cold_chain_flag":"Cold chain Y/N (Type 2)","storage_min_temp_c":"Min storage °C (Type 2)","storage_max_temp_c":"Max storage °C (Type 2)","max_humidity_pct":"Max humidity % (Type 2)","shelf_life_months":"Shelf life months","min_remaining_shelf_life_days":"Min remaining shelf life days","primary_supplier_id":"Primary supplier","primary_plant_id":"Primary plant","manufacturing_lead_time_days":"Mfg lead time days","standard_batch_size_packs":"Standard batch size","safety_stock_days":"Safety stock days","reorder_review_cycle_days":"Reorder review cycle days","unit_manufacturing_cost_usd":"Unit mfg cost USD (Type 2)","wholesale_price_usd":"Wholesale price USD (Type 2)","recommended_retail_price_usd":"RRP USD (Type 2)","product_status":"Product status (Type 2)","scd2_hash":"MD5 of Type-2 columns (change detection)","valid_from":"SCD2 version start","valid_to":"SCD2 version end (9999-12-31 = current)","is_current":"True for the current version","etl_batch_id":"Load batch that wrote the row","loaded_at":"Load timestamp"},
 "dim_pharmacy": {"pharmacy_key":"Surrogate key (-1 = Unknown)","pharmacy_id":"Natural key (PharmacyID)","pharmacy_gln":"GLN (13-digit text)","pharmacy_name":"Pharmacy name","pharmacy_type":"Chain / Independent / Hospital Pharmacy","linked_hospital_id":"Hospital for hospital pharmacies","city":"City","state":"State","country_code":"Country","etl_batch_id":"Load batch","updated_at":"Last update"},
 "dim_hospital": {"hospital_key":"Surrogate key (-1 = Not a hospital sale)","hospital_id":"Natural key (HospitalID)","hospital_gln":"GLN (13-digit text)","hospital_name":"Hospital name","hospital_type":"Hospital type","hospital_pharmacy_id":"Linked hospital pharmacy","city":"City","state":"State","country_code":"Country","licensed_beds":"Licensed beds","icu_beds":"ICU beds","avg_occupancy_rate_pct":"Avg occupancy %","trauma_level":"Trauma level ('Not designated' if empty)","catchment_population":"Catchment population","bed_size_band":"Derived: Small<400 / Medium 400–699 / Large 700+","etl_batch_id":"Load batch","updated_at":"Last update"},
 "dim_channel": {"channel_key":"Surrogate key (-1 = Unknown)","channel_code":"RETAIL / HOSPITAL / ECOM","channel_name":"Display name","channel_group":"Physical / Online"},
 "dim_sales_profile": {"sales_profile_key":"Surrogate key (-1 = Unknown)","prescription_required_flag":"Rx required Y/N","customer_segment":"Customer segment","payer_type":"Payer type","payment_method":"Payment method","promotion_code":"Promotion code ('None' = no promo)","has_promotion":"True if a promotion applied","ecommerce_delivery_status":"E-commerce delivery status","return_flag":"Return Y/N","sale_status":"Completed / Partially returned","delivery_otif_flag":"Delivery OTIF Y/N"},
 "dim_demand_status": {"demand_status_key":"Surrogate key (-1 = Unknown)","medication_request_status":"Completed / Partially fulfilled","formulary_status":"Formulary / Restricted / Non-formulary exception"},
}
title(ws, "Dimensions — one block per dimension (column types read from the DuckDB sdi schema)", 3)
r = 3
for dname in ["dim_date","dim_medicine","dim_pharmacy","dim_hospital","dim_channel","dim_sales_profile","dim_demand_status"]:
    typ, sk, nk, scd = DIM_META[dname]
    ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=3)
    c = ws.cell(row=r, column=1, value=f"{dname}"); c.fill = fill(BLUE); c.font = WHITE; r += 1
    r = label_block(ws, r, "Type", typ, value_span=1)
    r = label_block(ws, r, "Surrogate key", sk)
    r = label_block(ws, r, "Natural key", nk)
    r = label_block(ws, r, "SCD / handling", scd)
    header(ws, r, ["Attribute", "Data type", "Description"]); r += 1
    data = [[cn, ct, DESC.get(dname, {}).get(cn, "")] for cn, ct in SCHEMA[dname]]
    r = rows_out(ws, r, data, wrap_cols=(2,)); r += 1
widths(ws, [30, 16, 80]); ws.freeze_panes = "A3"

# ===================== 4. FACTS =====================
ws = wb.create_sheet("Facts")
FS = {
 "quantity_sold_packs":("Additive","Packs sold"),
 "returned_quantity_packs":("Additive","Packs returned"),
 "net_quantity_packs":("Additive","Derived = quantity_sold_packs − returned_quantity_packs"),
 "unit_retail_price_usd":("Non-additive","Unit price (do not sum; average)"),
 "gross_sales_usd":("Additive","Gross sales = unit price × qty"),
 "discount_usd":("Additive","Discount amount"),
 "net_sales_usd":("Additive","Net sales = gross − discount (revenue measure)"),
 "sales_tax_usd":("Additive","Sales tax"),
 "cogs_usd":("Additive","Cost of goods sold"),
 "gross_margin_usd":("Additive","Gross margin = net − COGS"),
 "days_to_expiry_at_sale":("Non-additive","Days from sale to batch expiry"),
 "dq_warning_count":("Additive (housekeeping)","# of WARN rules this row broke"),
}
FH = {
 "estimated_disease_cases":("Non-additive (context)","Per hospital-disease-month; do not sum across medicines (check C13)"),
 "disease_related_admissions":("Non-additive (context)","Per hospital-disease-month"),
 "outpatient_encounters":("Non-additive (context)","Per hospital-disease-month"),
 "forecast_demand_packs":("Additive","Forecast demand"),
 "requested_qty_packs":("Additive","Requested quantity"),
 "approved_qty_packs":("Additive","Approved quantity"),
 "received_qty_packs":("Additive","Received quantity"),
 "emergency_request_qty_packs":("Additive","Emergency requests"),
 "dispensed_qty_packs":("Additive","Dispensed quantity"),
 "consumed_qty_packs":("Additive","Consumed quantity"),
 "wastage_qty_packs":("Additive","Wastage"),
 "unfulfilled_demand_packs":("Additive","Unfulfilled demand"),
 "stockout_days":("Additive","Stockout days in the month"),
 "opening_stock_packs":("Semi-additive","Stock level — sum across hospitals, never across months"),
 "closing_stock_packs":("Semi-additive","Stock level — sum across hospitals, never across months"),
 "service_level_pct":("Non-additive","= dispensed / (dispensed + unfulfilled); average, do not sum"),
 "avg_lead_time_days":("Non-additive","Average lead time"),
 "demand_trend_index":("Non-additive","Demand trend index"),
 "forecast_error_packs":("Additive","Derived = consumed − forecast"),
 "dq_warning_count":("Additive (housekeeping)","# of WARN rules this row broke"),
}
FACT_META = {
 "fact_sales": ("Transaction", "One pharmacy sales transaction (one row of 05)",
   "sales_transaction_id (PK), pharmacy_order_id, pharmacy_delivery_id, prescription_id, production_batch_id, warehouse_lot_id, source_warehouse_id, source_system",
   ["sale_date_key → dim_date (role: sale date)","pharmacy_delivery_date_key → dim_date (role: delivery)","batch_expiry_date_key → dim_date (role: expiry)","medicine_key → dim_medicine (SCD2, version on sale date)","pharmacy_key → dim_pharmacy","hospital_key → dim_hospital (-1 if not a hospital sale)","channel_key → dim_channel","sales_profile_key → dim_sales_profile (junk)"], FS),
 "fact_hospital_demand": ("Periodic snapshot (monthly)", "One hospital × medicine × month (one row of 06)",
   "hospital_demand_record_id (PK)",
   ["month_date_key → dim_date (1st of month)","hospital_key → dim_hospital","medicine_key → dim_medicine (SCD2, version on month)","demand_status_key → dim_demand_status (junk)"], FH),
}
title(ws, "Facts — one block per fact (column types read from the DuckDB sdi schema)", 4)
r = 3
for fname in ["fact_sales","fact_hospital_demand"]:
    ftype, grain, degen, fks, meas = FACT_META[fname]
    ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=4)
    c = ws.cell(row=r, column=1, value=fname); c.fill = fill(BLUE); c.font = WHITE; r += 1
    r = label_block(ws, r, "Fact type", ftype, value_span=2)
    r = label_block(ws, r, "Grain", grain, value_span=2)
    r = label_block(ws, r, "Degenerate dims", degen, value_span=2)
    cc = ws.cell(row=r, column=1, value="Foreign keys → dimension"); cc.fill = fill(LIGHT); cc.font = BOLD; cc.border = BORDER
    ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=4)
    v = ws.cell(row=r, column=2, value="\n".join(fks)); v.alignment = WRAP; v.border = BORDER
    ws.row_dimensions[r].height = 14 * (len(fks) + 1); r += 1
    header(ws, r, ["Measure", "Data type", "Additivity", "Formula / description"]); r += 1
    typ = {cn: ct for cn, ct in SCHEMA[fname]}
    data = [[m, typ.get(m, ""), meas[m][0], meas[m][1]] for m in meas]
    r = rows_out(ws, r, data, wrap_cols=(3,)); r += 1
widths(ws, [30, 16, 22, 70]); ws.freeze_panes = "A3"

# ===================== 5. SOURCE-TO-TARGET =====================
ws = wb.create_sheet("Source-to-Target Mapping")
title(ws, "Source-to-target mapping — source file.column → ODS column → mart table.column → transformation", 5)
header(ws, 2, ["Source file", "Source column", "ODS column", "Target table.column", "Transformation"])
M = [
 ["01_master_data","MedicineID",'ods.master_data."MedicineID"',"dim_medicine.medicine_id","Natural key; keep latest row per MedicineID"],
 ["01_master_data","GTIN14",' "GTIN14"',"dim_medicine.gtin14","lpad to 14 digits (preserve leading zero)"],
 ["01_master_data","RecommendedRetailPriceUSD",' "RecommendedRetailPriceUSD"',"dim_medicine.recommended_retail_price_usd","CAST → DECIMAL(12,4); SCD2-tracked (price change → new version)"],
 ["01_master_data","UnitManufacturingCostUSD / WholesalePriceUSD",' "…USD"',"dim_medicine.unit_manufacturing_cost_usd / wholesale_price_usd","CAST → DECIMAL; part of scd2_hash"],
 ["01_master_data","PrescriptionClass, ColdChainFlag, StorageMin/MaxTempC, MaxHumidityPct, ProductStatus",'ods.master_data.*',"dim_medicine.* (same)","CAST where numeric; part of scd2_hash (Type-2 attributes)"],
 ["01_master_data","GenericName, BrandName, DiseaseCategory, ATCCode, DosageForm, … (descriptive)",'ods.master_data.*',"dim_medicine.* (same)","Copied as text; Type-1 overwrite on refresh"],
 ["01_master_data","EffectiveFromDate",' "EffectiveFromDate"',"dim_medicine.valid_from","CAST → DATE; first version start (later versions use run date)"],
 ["(derived)","md5(Type-2 columns)","—","dim_medicine.scd2_hash","MD5 for change detection; drives valid_to / is_current"],
 ["05_pharmacy_sales_data","PharmacyID + attributes",'ods.pharmacy_sales."Pharmacy*"',"dim_pharmacy.*","DISTINCT per PharmacyID; SCD1 upsert; linked_hospital_id = max(HospitalID)"],
 ["06_hospital_demand_data","HospitalID + attributes",'ods.hospital_demand."Hospital*"',"dim_hospital.*","DISTINCT per HospitalID; SCD1 upsert; bed_size_band derived from LicensedBeds"],
 ["05_pharmacy_sales_data","SalesChannel + PharmacyType",'ods.pharmacy_sales.*',"fact_sales.channel_key → dim_channel","Derive code: Ecommerce→ECOM; else Hospital Pharmacy→HOSPITAL; else RETAIL"],
 ["05_pharmacy_sales_data","9 flags (Rx/segment/payer/payment/promo/ecom/return/sale/OTIF)",'ods.pharmacy_sales.*',"fact_sales.sales_profile_key → dim_sales_profile","Empty PromotionCode→'NONE'; insert new combo; lookup junk key"],
 ["06_hospital_demand_data","MedicationRequestStatus + FormularyStatus",'ods.hospital_demand.*',"fact_hospital_demand.demand_status_key → dim_demand_status","Insert new combo; lookup junk key"],
 ["05_pharmacy_sales_data","SalesTransactionID",'ods.pharmacy_sales."SalesTransactionID"',"fact_sales.sales_transaction_id","Degenerate PK; skip if already in fact_sales (rule S1)"],
 ["05_pharmacy_sales_data","SalesDate",' "SalesDate"',"fact_sales.sale_date_key","CAST → DATE → lookup dim_date (-1 if missing)"],
 ["05_pharmacy_sales_data","PharmacyDeliveryDate / BatchExpiryDate",'ods.pharmacy_sales.*',"fact_sales.pharmacy_delivery_date_key / batch_expiry_date_key","CAST → DATE → lookup dim_date (role-playing)"],
 ["05_pharmacy_sales_data","MedicineID",' "MedicineID"',"fact_sales.medicine_key","SCD2 lookup: dim_medicine version valid on SalesDate (-1 if none)"],
 ["05_pharmacy_sales_data","PharmacyID / HospitalID",'ods.pharmacy_sales.*',"fact_sales.pharmacy_key / hospital_key","Lookup dim; HospitalID empty → hospital_key = -1"],
 ["05_pharmacy_sales_data","QuantitySoldPacks, UnitRetailPriceUSD, Gross/Discount/Net/Tax/COGS/Margin",'ods.pharmacy_sales.*',"fact_sales.* (measures)","CAST → INTEGER / DECIMAL(12,2); copied (validated by S6–S10)"],
 ["(derived)","QuantitySold − Returned","—","fact_sales.net_quantity_packs","Computed"],
 ["05_pharmacy_sales_data","SalesTimestampUTC",' "SalesTimestampUTC"',"fact_sales.sales_timestamp_utc","Strip trailing 'Z'; CAST → TIMESTAMP"],
 ["05_pharmacy_sales_data","Order/Delivery/Prescription/Batch/Lot/Warehouse IDs",'ods.pharmacy_sales.*',"fact_sales.* (degenerate)","Copied as text"],
 ["06_hospital_demand_data","HospitalDemandRecordID",'ods.hospital_demand."HospitalDemandRecordID"',"fact_hospital_demand.hospital_demand_record_id","Degenerate PK; skip if already loaded (rule H1)"],
 ["06_hospital_demand_data","DemandMonth",' "DemandMonth"',"fact_hospital_demand.month_date_key","CAST → DATE (1st of month) → lookup dim_date"],
 ["06_hospital_demand_data","MedicineID / HospitalID",'ods.hospital_demand.*',"fact_hospital_demand.medicine_key / hospital_key","SCD2 / dim lookup"],
 ["06_hospital_demand_data","Forecast/Requested/…/Stockout + Opening/Closing + ServiceLevel + LeadTime + TrendIndex",'ods.hospital_demand.*',"fact_hospital_demand.* (measures)","CAST → INTEGER / DECIMAL; copied (validated by H5–H9)"],
 ["(derived)","Consumed − Forecast","—","fact_hospital_demand.forecast_error_packs","Computed"],
]
r = rows_out(ws, 3, M, wrap_cols=(1,2,3,4))
widths(ws, [24, 34, 30, 34, 52]); ws.freeze_panes = "A3"

# ===================== 6. VALIDATION RULES =====================
ws = wb.create_sheet("Validation Rules")
RULES = [
 ("M1","ods.master_data","MedicineID not empty and unique","REJECT"),
 ("M2","ods.master_data","Mfg cost, wholesale, RRP all > 0","REJECT"),
 ("M3","ods.master_data","Mfg cost ≤ wholesale ≤ RRP","WARN"),
 ("M4","ods.master_data","StorageMinTempC < StorageMaxTempC","REJECT"),
 ("M5","ods.master_data","Y/N flags valid; PrescriptionClass ∈ {Prescription, OTC}","REJECT"),
 ("M6","ods.master_data","GTIN14 is 14 digits (after zero-pad)","REJECT"),
 ("S1","ods.pharmacy_sales","SalesTransactionID not empty, unique, not already in fact_sales","REJECT"),
 ("S2","ods.pharmacy_sales","MedicineID not empty and exists in dim_medicine","REJECT"),
 ("S3","ods.pharmacy_sales","PharmacyID not empty","REJECT"),
 ("S4","ods.pharmacy_sales","SalesDate valid and in 2023-01-01 … run date","REJECT"),
 ("S5","ods.pharmacy_sales","SalesDate = date part of SalesTimestampUTC","WARN"),
 ("S6","ods.pharmacy_sales","UnitRetailPriceUSD > 0","REJECT"),
 ("S7","ods.pharmacy_sales","QuantitySoldPacks ≥ 1","REJECT"),
 ("S8","ods.pharmacy_sales","Gross = UnitPrice × Qty (±0.01)","WARN"),
 ("S9","ods.pharmacy_sales","Net = Gross − Discount (±0.01); 0 ≤ Discount ≤ Gross","WARN"),
 ("S10","ods.pharmacy_sales","GrossMargin = Net − COGS (±0.01)","WARN"),
 ("S11","ods.pharmacy_sales","0 ≤ Returned ≤ Qty; ReturnFlag=Y ⇔ Returned>0","WARN"),
 ("S12","ods.pharmacy_sales","PharmacyDeliveryDate ≤ SalesDate","WARN"),
 ("S13","ods.pharmacy_sales","Rx required ⇒ PrescriptionID not empty","WARN"),
 ("S14","ods.pharmacy_sales","BatchExpiryDate ≥ SalesDate (nothing expired)","WARN"),
 ("S15","ods.pharmacy_sales","HospitalID filled ⇔ PharmacyType = Hospital Pharmacy","WARN"),
 ("S16","ods.pharmacy_sales","Coded columns contain known values","WARN"),
 ("H1","ods.hospital_demand","RecordID not empty, unique, not already in mart","REJECT"),
 ("H2","ods.hospital_demand","(HospitalID, MedicineID, DemandMonth) unique","REJECT"),
 ("H3","ods.hospital_demand","DemandMonth valid, 1st of month, in range","REJECT"),
 ("H4","ods.hospital_demand","MedicineID in dim_medicine; HospitalID not empty","REJECT"),
 ("H5","ods.hospital_demand","All quantity columns ≥ 0","REJECT"),
 ("H6","ods.hospital_demand","Approved ≤ Requested; Received ≤ Approved","WARN"),
 ("H7","ods.hospital_demand","Closing = Opening + Received − Dispensed − Wastage","WARN"),
 ("H8","ods.hospital_demand","ServiceLevelPct between 0 and 100","REJECT"),
 ("H9","ods.hospital_demand","StockoutDays between 0 and days-in-month","REJECT"),
]
title(ws, f"Validation rules (M/S/H) — counts from the latest refresh run: {DQ_BATCH or 'n/a'}", 6)
header(ws, 2, ["Rule", "Table", "Check", "Action", "Rows checked", "Rows caught"])
data = []
for rid, tbl, chk, act in RULES:
    checked, failed = DQ.get(rid, (None, None))
    data.append([rid, tbl, chk, act, checked if checked is not None else "", failed if failed is not None else ""])
r = rows_out(ws, 3, data, wrap_cols=(2,))
for i, (rid, tbl, chk, act) in enumerate(RULES):
    rr = 3 + i
    ac = ws.cell(row=rr, column=4); ac.alignment = CENTER
    ac.fill = fill("F4B183" if act == "REJECT" else "FFE699")
    fc = ws.cell(row=rr, column=6); fc.alignment = CENTER
    if isinstance(fc.value, int) and fc.value > 0:
        fc.fill = fill("F4B183"); fc.font = BOLD
    ws.cell(row=rr, column=5).alignment = CENTER
    ws.cell(row=rr, column=1).alignment = CENTER
widths(ws, [8, 22, 60, 10, 14, 14]); ws.freeze_panes = "A3"

wb.save(str(OUT))
print("saved:", OUT)
print("sheets:", wb.sheetnames)
print("dq batch used:", DQ_BATCH)
