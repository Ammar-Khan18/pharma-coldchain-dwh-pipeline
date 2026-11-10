"""
Phase 1 assumption checks  (follow-up to WBS 1.4, feeds WBS 3.2.2 validation rules)

WHAT IT DOES
  Reads 01_master, 05_pharmacy_sales and 06_hospital_demand straight from the CSVs
  with DuckDB (nothing is loaded into Postgres or the mart) and answers the questions
  the star-schema design depends on: how to derive the 3 sales channels, whether the
  money columns add up, whether hospital stock balances, etc.

WHERE TO RUN
  Ubuntu (WSL) terminal, with the venv active:
      source ~/ida-project/.venv/bin/activate
      python ~/pipeline/ingestion/check_phase1_assumptions.py

OUTPUT
  Prints to screen and writes ~/pipeline/docs/phase1_assumption_checks.md
  Optional args: <data_dir> <output_md>
"""
import sys
import time
from datetime import datetime
from pathlib import Path

import duckdb

DATA = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path.home() / "pipeline" / "data"
OUT = (Path(sys.argv[2]).expanduser() if len(sys.argv) > 2
       else Path.home() / "pipeline" / "docs" / "phase1_assumption_checks.md")

FILES = {
    "master": "01_master_data.csv",
    "sales": "05_pharmacy_sales_data.csv",
    "demand": "06_hospital_demand_data.csv",
}

# Helpers used inside SQL --------------------------------------------------
# Every column is read as TEXT (all_varchar) so nothing is silently changed
# (e.g. leading zeros in GTIN/GLN). We cast explicitly where we need numbers.
EMPTY = "coalesce(trim({c}), '') = ''"


def num(c):
    return f"TRY_CAST({c} AS DOUBLE)"


def ts(c):  # '2023-11-12T13:43:13Z' -> naive UTC timestamp
    return f"TRY_CAST(replace(replace({c}, 'T', ' '), 'Z', '') AS TIMESTAMP)"


CHECKS = [
    # (id, title, what we hope to see, sql)
    ("C1", "Sales channel mix (how to derive Retail / Hospital / E-commerce)",
     "Each SalesChannel x PharmacyType combo maps cleanly to one business channel; "
     "HospitalID is filled only for Hospital Pharmacy rows.",
     f"""SELECT SalesChannel, PharmacyType,
                CASE WHEN {EMPTY.format(c='HospitalID')} THEN 'empty' ELSE 'filled' END AS hospital_id,
                SourceSystem, COUNT(*) AS n_rows
         FROM sales GROUP BY ALL ORDER BY n_rows DESC"""),

    ("C2", "Hospital pharmacy -> hospital mapping (05 vs 06)",
     "Every pharmacy that has a HospitalID maps to exactly one hospital, and it matches "
     "06.HospitalPharmacyID.",
     f"""WITH s AS (SELECT PharmacyID, COUNT(DISTINCT HospitalID) AS n_hospitals,
                           MIN(HospitalID) AS hospital_in_sales
                    FROM sales WHERE NOT {EMPTY.format(c='HospitalID')} GROUP BY 1),
              d AS (SELECT DISTINCT HospitalID, HospitalPharmacyID FROM demand)
         SELECT s.PharmacyID, s.n_hospitals, s.hospital_in_sales,
                d.HospitalID AS hospital_in_demand,
                (d.HospitalID = s.hospital_in_sales) AS matches
         FROM s LEFT JOIN d ON d.HospitalPharmacyID = s.PharmacyID ORDER BY 1"""),

    ("C3", "Pharmacy attributes stable per PharmacyID (dimension candidate)",
     "0 pharmacies with changing attributes -> dim_pharmacy can be built from distinct rows.",
     """SELECT COUNT(*) AS pharmacies,
               COUNT(*) FILTER (WHERE n_name>1 OR n_type>1 OR n_city>1 OR n_state>1
                                 OR n_gln>1 OR n_hosp>1) AS pharmacies_with_changing_attrs
        FROM (SELECT PharmacyID,
                     COUNT(DISTINCT PharmacyName) n_name, COUNT(DISTINCT PharmacyType) n_type,
                     COUNT(DISTINCT PharmacyCity) n_city, COUNT(DISTINCT PharmacyState) n_state,
                     COUNT(DISTINCT PharmacyGLN) n_gln, COUNT(DISTINCT HospitalID) n_hosp
              FROM sales GROUP BY 1)"""),

    ("C4", "Hospital attributes stable per HospitalID (dimension candidate)",
     "0 hospitals with changing attributes -> dim_hospital from distinct rows.",
     """SELECT COUNT(*) AS hospitals,
               COUNT(*) FILTER (WHERE greatest(n1,n2,n3,n4,n5,n6,n7,n8,n9,n10,n11) > 1)
                   AS hospitals_with_changing_attrs
        FROM (SELECT HospitalID,
                     COUNT(DISTINCT HospitalName) n1, COUNT(DISTINCT HospitalType) n2,
                     COUNT(DISTINCT HospitalPharmacyID) n3, COUNT(DISTINCT City) n4,
                     COUNT(DISTINCT State) n5, COUNT(DISTINCT LicensedBeds) n6,
                     COUNT(DISTINCT ICUBeds) n7, COUNT(DISTINCT AverageOccupancyRatePct) n8,
                     COUNT(DISTINCT coalesce(TraumaLevel,'-')) n9,
                     COUNT(DISTINCT CatchmentPopulation) n10, COUNT(DISTINCT HospitalGLN) n11
              FROM demand GROUP BY 1)"""),

    ("C5", "Prescription flag vs PrescriptionID",
     "Flag Y -> PrescriptionID filled; flag N -> empty. Flag should also match master PrescriptionClass.",
     f"""SELECT s.PrescriptionRequiredFlag, m.PrescriptionClass,
                CASE WHEN {EMPTY.format(c='s.PrescriptionID')} THEN 'empty' ELSE 'filled' END AS rx_id,
                COUNT(*) AS n_rows
         FROM sales s LEFT JOIN master m USING (MedicineID) GROUP BY ALL ORDER BY ALL"""),

    ("C6", "Money formulas in sales (counts of rows that break each formula, tolerance 1 cent)",
     "All zeros -> we can trust the source amounts and use them as rules.",
     f"""WITH t AS (
           SELECT {num('s.UnitRetailPriceUSD')} p, {num('s.QuantitySoldPacks')} q,
                  {num('s.GrossSalesAmountUSD')} g, {num('s.DiscountAmountUSD')} d,
                  {num('s.NetSalesAmountUSD')} n, {num('s.CostOfGoodsSoldUSD')} c,
                  {num('s.GrossMarginUSD')} mg, {num('s.SalesTaxUSD')} tx,
                  {num('m.WholesalePriceUSD')} wp, {num('m.RecommendedRetailPriceUSD')} rrp
           FROM sales s LEFT JOIN master m USING (MedicineID))
         SELECT COUNT(*) AS n_rows,
           COUNT(*) FILTER (WHERE p IS NULL OR p <= 0) AS price_not_positive,
           COUNT(*) FILTER (WHERE q IS NULL OR q <= 0) AS qty_not_positive,
           COUNT(*) FILTER (WHERE abs(p*q - g) > 0.011) AS gross_ne_price_x_qty,
           COUNT(*) FILTER (WHERE abs(g - d - n) > 0.011) AS net_ne_gross_minus_disc,
           COUNT(*) FILTER (WHERE abs(n - c - mg) > 0.011) AS margin_ne_net_minus_cogs,
           COUNT(*) FILTER (WHERE abs(c - q*wp) > 0.011) AS cogs_ne_qty_x_wholesale,
           COUNT(*) FILTER (WHERE abs(p - rrp) > 0.001) AS price_ne_master_rrp,
           COUNT(*) FILTER (WHERE d < 0 OR d > g) AS bad_discount,
           COUNT(*) FILTER (WHERE mg < 0) AS negative_margin,
           round(avg(tx / nullif(n, 0)), 4) AS avg_tax_rate
         FROM t"""),

    ("C7", "Sales date checks",
     "SalesDate = date part of SalesTimestampUTC; delivery to pharmacy before the sale; "
     "no expired stock sold; DaysToExpiryAtSale = ExpiryDate - SalesDate.",
     f"""WITH t AS (SELECT TRY_CAST(SalesDate AS DATE) sd, {ts('SalesTimestampUTC')} st,
                           TRY_CAST(PharmacyDeliveryDate AS DATE) dd,
                           TRY_CAST(BatchExpiryDate AS DATE) ed,
                           TRY_CAST(DaysToExpiryAtSale AS INTEGER) dte FROM sales)
         SELECT COUNT(*) FILTER (WHERE sd IS NULL) AS bad_sales_date,
                COUNT(*) FILTER (WHERE st IS NULL) AS bad_timestamp,
                COUNT(*) FILTER (WHERE sd <> CAST(st AS DATE)) AS date_ne_timestamp_date,
                COUNT(*) FILTER (WHERE dd > sd) AS delivered_after_sale,
                COUNT(*) FILTER (WHERE ed < sd) AS expired_at_sale,
                COUNT(*) FILTER (WHERE dte <> date_diff('day', sd, ed)) AS days_to_expiry_mismatch,
                MIN(sd) AS first_sale, MAX(sd) AS last_sale
         FROM t"""),

    ("C8", "Returns consistency",
     "ReturnFlag=Y <-> ReturnedQuantityPacks>0 <-> SaleStatus='Partially returned'.",
     """SELECT ReturnFlag, SaleStatus, ReturnedQuantityPacks, COUNT(*) AS n_rows
        FROM sales GROUP BY ALL ORDER BY ALL"""),

    ("C9", "E-commerce delivery status vs channel",
     "'Not applicable' only for physical sales.",
     """SELECT SalesChannel, EcommerceDeliveryStatus, COUNT(*) AS n_rows
        FROM sales GROUP BY ALL ORDER BY ALL"""),

    ("C10", "Medicine attributes repeated in 05/06 agree with master",
     "All zeros -> we drop GenericName/DiseaseCategory/GTIN14 from the facts and take them from dim_medicine.",
     """SELECT 'sales' AS src,
               COUNT(*) FILTER (WHERE m.MedicineID IS NULL) AS orphan_medicine,
               COUNT(*) FILTER (WHERE x.GenericName <> m.GenericName) AS generic_mismatch,
               COUNT(*) FILTER (WHERE x.DiseaseCategory <> m.DiseaseCategory) AS disease_mismatch,
               COUNT(*) FILTER (WHERE x.GTIN14 <> m.GTIN14) AS gtin_mismatch
        FROM sales x LEFT JOIN master m USING (MedicineID)
        UNION ALL
        SELECT 'demand',
               COUNT(*) FILTER (WHERE m.MedicineID IS NULL),
               COUNT(*) FILTER (WHERE x.GenericName <> m.GenericName),
               COUNT(*) FILTER (WHERE x.DiseaseCategory <> m.DiseaseCategory),
               COUNT(*) FILTER (WHERE x.GTIN14 <> m.GTIN14)
        FROM demand x LEFT JOIN master m USING (MedicineID)"""),

    ("C11", "Hospital demand grain",
     "rows = ids = grain_combos = 12 x 63 x 36 = 27,216 and 0 bad months.",
     """SELECT COUNT(*) AS n_rows, COUNT(DISTINCT HospitalDemandRecordID) AS ids,
               COUNT(DISTINCT concat_ws('|', HospitalID, MedicineID, DemandMonth)) AS grain_combos,
               COUNT(DISTINCT HospitalID) AS hospitals, COUNT(DISTINCT MedicineID) AS medicines,
               COUNT(DISTINCT DemandMonth) AS months,
               MIN(DemandMonth) AS first_month, MAX(DemandMonth) AS last_month,
               COUNT(*) FILTER (WHERE TRY_CAST(DemandMonth AS DATE) IS NULL
                                 OR day(TRY_CAST(DemandMonth AS DATE)) <> 1) AS bad_month
        FROM demand"""),

    ("C12", "Hospital demand quantity rules (counts of rows that break each candidate rule)",
     "Tells us which stock-balance / service-level formula the source actually uses.",
     f"""WITH t AS (
           SELECT HospitalID, MedicineID, TRY_CAST(DemandMonth AS DATE) mo,
                  {num('ForecastDemandPacks')} f, {num('RequestedQuantityPacks')} r,
                  {num('ApprovedQuantityPacks')} a, {num('ReceivedQuantityPacks')} rc,
                  {num('EmergencyRequestQuantityPacks')} e, {num('OpeningStockPacks')} o,
                  {num('DispensedQuantityPacks')} di, {num('ConsumedQuantityPacks')} co,
                  {num('WastageQuantityPacks')} w, {num('ClosingStockPacks')} cl,
                  {num('UnfulfilledDemandPacks')} u, {num('StockoutDays')} sod,
                  {num('ServiceLevelPct')} sl
           FROM demand),
         t2 AS (SELECT *, lag(cl) OVER (PARTITION BY HospitalID, MedicineID ORDER BY mo) AS prev_cl FROM t)
         SELECT COUNT(*) AS n_rows,
           COUNT(*) FILTER (WHERE least(f,r,a,rc,e,o,di,co,w,cl,u,sod) < 0) AS any_negative,
           COUNT(*) FILTER (WHERE a > r) AS approved_gt_requested,
           COUNT(*) FILTER (WHERE rc > a) AS received_gt_approved,
           COUNT(*) FILTER (WHERE co > di) AS consumed_gt_dispensed,
           COUNT(*) FILTER (WHERE cl <> o + rc - di - w) AS close_ne_open_plus_rec_minus_disp_minus_waste,
           COUNT(*) FILTER (WHERE cl <> greatest(o + rc - di - w, 0)) AS close_ne_same_floored_at_0,
           COUNT(*) FILTER (WHERE prev_cl IS NOT NULL AND o <> prev_cl) AS opening_ne_prev_closing,
           COUNT(*) FILTER (WHERE u <> greatest(r - rc, 0)) AS unfulfilled_ne_req_minus_rec,
           COUNT(*) FILTER (WHERE abs(sl - 100.0*rc/nullif(r,0)) > 0.06) AS sl_ne_rec_over_req,
           COUNT(*) FILTER (WHERE abs(sl - 100.0*di/nullif(di+u,0)) > 0.06) AS sl_ne_disp_over_disp_plus_unf,
           COUNT(*) FILTER (WHERE sl < 0 OR sl > 100) AS sl_out_of_range,
           COUNT(*) FILTER (WHERE sod > day(last_day(mo))) AS stockout_days_gt_month,
           round(avg(co / nullif(f, 0)), 3) AS avg_consumed_over_forecast
         FROM t2"""),

    ("C13", "Are disease-level measures repeated for every medicine of a disease?",
     "If groups_where_value_differs = 0, EstimatedDiseaseCases etc. are per hospital-disease-month "
     "and must NOT be summed across medicines.",
     """SELECT COUNT(*) AS hospital_disease_month_groups,
               COUNT(*) FILTER (WHERE n_cases > 1 OR n_adm > 1 OR n_out > 1) AS groups_where_value_differs
        FROM (SELECT HospitalID, DiseaseCategory, DemandMonth,
                     COUNT(DISTINCT EstimatedDiseaseCases) n_cases,
                     COUNT(DISTINCT DiseaseRelatedAdmissions) n_adm,
                     COUNT(DISTINCT OutpatientEncounters) n_out
              FROM demand GROUP BY ALL)"""),

    ("C14", "Junk dimension size (distinct combos of low-cardinality sales flags)",
     "A few hundred combos at most -> one small junk dimension is fine.",
     """SELECT COUNT(*) AS distinct_combos FROM (
          SELECT DISTINCT PrescriptionRequiredFlag, CustomerSegment, PayerType, PaymentMethod,
                 coalesce(PromotionCode, 'NONE'), EcommerceDeliveryStatus, ReturnFlag,
                 SaleStatus, DeliveryOTIFFlag FROM sales)"""),

    ("C15", "Master price ladder",
     "UnitManufacturingCost <= Wholesale <= RRP for every medicine.",
     f"""SELECT COUNT(*) AS medicines,
               COUNT(*) FILTER (WHERE {num('UnitManufacturingCostUSD')} > {num('WholesalePriceUSD')}) AS cost_gt_wholesale,
               COUNT(*) FILTER (WHERE {num('WholesalePriceUSD')} > {num('RecommendedRetailPriceUSD')}) AS wholesale_gt_rrp,
               COUNT(*) FILTER (WHERE {num('StorageMinTempC')} >= {num('StorageMaxTempC')}) AS bad_temp_range,
               COUNT(*) FILTER (WHERE length(GTIN14) <> 14) AS gtin_not_14_chars
        FROM master"""),
]

# Low-cardinality columns whose allowed values become domain rules
DOMAINS = {
    "sales": ["SalesChannel", "PharmacyType", "CustomerSegment", "PayerType", "PaymentMethod",
              "PromotionCode", "EcommerceDeliveryStatus", "SaleStatus", "SourceSystem",
              "DeliveryOTIFFlag", "ReturnFlag", "PrescriptionRequiredFlag"],
    "demand": ["HospitalType", "TraumaLevel", "MedicationRequestStatus", "FormularyStatus"],
}


def md_table(cols, rows):
    out = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    for r in rows:
        out.append("| " + " | ".join("" if v is None else f"{v:,}" if isinstance(v, int) and not isinstance(v, bool) else str(v) for v in r) + " |")
    return "\n".join(out)


def main():
    t0 = time.time()
    con = duckdb.connect()
    for tbl, fname in FILES.items():
        path = DATA / fname
        if not path.exists():
            sys.exit(f"Missing file: {path}")
        con.execute(f"CREATE TABLE {tbl} AS SELECT * FROM read_csv('{path.as_posix()}', "
                    f"all_varchar=true, header=true)")
        print(f"loaded {fname}: {con.execute(f'SELECT COUNT(*) FROM {tbl}').fetchone()[0]:,} rows")

    lines = [f"# Phase 1 assumption checks", "",
             f"Generated: {datetime.now():%Y-%m-%d %H:%M} from `{DATA}`", ""]
    for cid, title, expect, sql in CHECKS:
        lines += [f"## {cid}. {title}", "", f"_Hoping to see:_ {expect}", ""]
        try:
            cur = con.execute(sql)
            cols = [d[0] for d in cur.description]
            lines.append(md_table(cols, cur.fetchall()))
        except Exception as exc:  # keep going; report the error
            lines.append(f"**ERROR:** `{exc}`")
        lines.append("")

    lines += ["## Allowed values (domain rules)", ""]
    for tbl, cols in DOMAINS.items():
        for c in cols:
            vals = con.execute(f"SELECT coalesce({c}, '<empty>') v, COUNT(*) n FROM {tbl} "
                               f"GROUP BY 1 ORDER BY n DESC").fetchall()
            lines.append(f"- **{tbl}.{c}**: " + ", ".join(f"{v} ({n:,})" for v, n in vals))
    lines.append("")

    text = "\n".join(lines)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(text)
    print(f"\nWrote {OUT}  ({time.time() - t0:.1f} s)")


if __name__ == "__main__":
    main()
