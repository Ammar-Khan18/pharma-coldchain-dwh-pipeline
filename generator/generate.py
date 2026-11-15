"""
generate.py  —  Phase 1 data oversampling / generator (WBS 2.1).

Simulates a new business month so the warehouse and dashboards visibly update on
a refresh. New rows are APPENDED (never replacing history): each refresh writes
one fresh month of 05 pharmacy sales and 06 hospital demand (and, optionally, a
changed 01 master file) into LANDING_DIR, where the file-watcher / sdi_ingest DAG
picks them up and the ingest → transform → query/storage chain runs.

Method (bootstrap oversampling — see docs/generator_method.md):
  * Sales/demand rows are RESAMPLED from real history for the same month-of-year
    (so seasonality, and the per-medicine / channel / pharmacy / hospital mix,
    match the real distributions), then only the identifiers and dates are moved
    into the new period. Every amount, flag and attribute is copied verbatim from
    a real row, so referential integrity holds (only existing MedicineID /
    pharmacy / hospital IDs appear) and the validation rules pass.
  * New SalesTransactionID / HospitalDemandRecordID continue the existing number
    sequence (read from the ODS), so they never collide.
  * Every column, text format, GTIN14 leading zero and date format is preserved,
    so ingestion and validation treat the file exactly like real data.

Options:
  --period YYYY-MM     the month to simulate (refresh 1 = 2026-01, refresh 2 = 2026-02)
  --price-change N     change the retail price of N medicines in a new 01 master
                       file, so dim_medicine (SCD Type 2) gains new versions
  --bad-rows N         add N deliberately invalid rows to the sales file to prove
                       validation rejects them (one per rule: S6, S4, S2, S3, S7)

Run (Ubuntu/WSL, venv active):
  python ~/pipeline/generator/generate.py --period 2026-01 --price-change 3 --bad-rows 5
Env: SOURCE_DIR (~/pipeline/data), LANDING_DIR (~/pipeline/landing), IDA_PG_DSN.
"""
import argparse
import calendar
import csv
import os
import random
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

import psycopg2

SOURCE_DIR = Path(os.environ.get("SOURCE_DIR", str(Path.home() / "pipeline" / "data")))
LANDING_DIR = Path(os.environ.get("LANDING_DIR", str(Path.home() / "pipeline" / "landing")))
PG_DSN = os.environ.get(
    "IDA_PG_DSN",
    "host=localhost port=5432 dbname=ida_staging user=ida_user password=ida_pass",
)

SALES_SRC = "05_pharmacy_sales_data.csv"
DEMAND_SRC = "06_hospital_demand_data.csv"
MASTER_SRC = "01_master_data.csv"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def _read_header(path: Path) -> list[str]:
    with open(path, encoding="utf-8", newline="") as fh:
        return next(csv.reader(fh))


def _idx(header: list[str]) -> dict:
    return {name: i for i, name in enumerate(header)}


def _next_seq(cur, table: str, col: str, prefix_len: int) -> int:
    """The next free integer for an ID like 'SALE-000500000' (continues history)."""
    cur.execute(f'SELECT max(CAST(substr("{col}", {prefix_len + 1}) AS BIGINT)) FROM ods.{table}')
    mx = cur.fetchone()[0]
    return (mx or 0) + 1


def _avg_monthly_sales(cur) -> int:
    cur.execute('SELECT count(*) FROM ods.pharmacy_sales')
    total = cur.fetchone()[0]
    cur.execute('SELECT count(DISTINCT substr("SalesDate", 1, 7)) FROM ods.pharmacy_sales')
    months = cur.fetchone()[0] or 1
    return max(1, round(total / months))


def _rand_day(year: int, month: int) -> date:
    return date(year, month, random.randint(1, calendar.monthrange(year, month)[1]))


# ---------------------------------------------------------------------------
# 05 pharmacy sales
# ---------------------------------------------------------------------------
def _reservoir_sample_sales(src: Path, col: dict, month_mm: str, k: int) -> list[list[str]]:
    """Stream the sales file and reservoir-sample k rows whose SalesDate is in the
    target month-of-year (seasonality); fall back to all months if too few."""
    si = col["SalesDate"]
    season, allrows_res, n_season, n_all = [], [], 0, 0
    with open(src, encoding="utf-8", newline="") as fh:
        r = csv.reader(fh)
        next(r)
        for row in r:
            # reservoir over ALL rows (fallback)
            n_all += 1
            if len(allrows_res) < k:
                allrows_res.append(row)
            else:
                j = random.randint(0, n_all - 1)
                if j < k:
                    allrows_res[j] = row
            # reservoir over same-month rows (preferred)
            if len(row) > si and row[si][5:7] == month_mm:
                n_season += 1
                if len(season) < k:
                    season.append(row)
                else:
                    j = random.randint(0, n_season - 1)
                    if j < k:
                        season[j] = row
    base = season if len(season) >= max(500, k // 4) else allrows_res
    # top up with replacement if the pool is smaller than k
    while len(base) < k:
        base.append(random.choice(base))
    return base[:k]


def _bad_sales_rows(template: list[str], col: dict, start_id: int, n: int) -> list[list[str]]:
    """n invalid rows, each breaking exactly one REJECT rule."""
    breakers = [
        ("UnitRetailPriceUSD", "-4.50", "S6 negative price"),
        ("SalesDate", "2026-13-40", "S4 invalid date"),
        ("MedicineID", "", "S2 missing MedicineID"),
        ("PharmacyID", "", "S3 missing pharmacy"),
        ("QuantitySoldPacks", "0", "S7 zero quantity"),
    ]
    out = []
    for i in range(n):
        row = list(template)
        row[col["SalesTransactionID"]] = f"SALE-{start_id + i:09d}"
        field, value, _ = breakers[i % len(breakers)]
        row[col[field]] = value
        out.append(row)
    return out


def generate_sales(period: str, year: int, month: int, k: int, bad_rows: int,
                   cur, header: list[str], col: dict) -> dict:
    src = SOURCE_DIR / SALES_SRC
    mm = f"{month:02d}"
    sampled = _reservoir_sample_sales(src, col, mm, k)
    next_sale = _next_seq(cur, "pharmacy_sales", "SalesTransactionID", len("SALE-"))

    rows, dates = [], []
    for s in sampled:
        row = list(s)
        d = _rand_day(year, month)
        dates.append(d)
        row[col["SalesTransactionID"]] = f"SALE-{next_sale:09d}"
        next_sale += 1
        row[col["SalesDate"]] = d.isoformat()
        row[col["SalesTimestampUTC"]] = (
            f"{d.isoformat()}T{random.randint(8,20):02d}:{random.randint(0,59):02d}:"
            f"{random.randint(0,59):02d}Z")
        # keep the batch unexpired at the new sale date (S14) and fix DaysToExpiry
        exp = d + timedelta(days=random.randint(200, 1000))
        row[col["BatchExpiryDate"]] = exp.isoformat()
        row[col["DaysToExpiryAtSale"]] = str((exp - d).days)
        rows.append(row)

    bad = _bad_sales_rows(sampled[0], col, next_sale, bad_rows) if bad_rows else []
    out_name = f"05_pharmacy_sales_data__gen_{period}.csv"
    _write_csv(LANDING_DIR / out_name, header, rows + bad)
    return {"source_file": out_name, "rows_generated": len(rows), "bad_rows": len(bad),
            "min_date": min(dates), "max_date": max(dates)}


# ---------------------------------------------------------------------------
# 06 hospital demand
# ---------------------------------------------------------------------------
def generate_demand(period: str, year: int, month: int, cur,
                    header: list[str], col: dict) -> dict:
    src = SOURCE_DIR / DEMAND_SRC
    mm = f"{month:02d}"
    hi, mi, di = col["HospitalID"], col["MedicineID"], col["DemandMonth"]
    season, anyrow = {}, {}
    with open(src, encoding="utf-8", newline="") as fh:
        r = csv.reader(fh)
        next(r)
        for row in r:
            key = (row[hi], row[mi])
            anyrow[key] = row
            if row[di][5:7] == mm:
                season[key] = row          # keep the latest same-month row per pair
    pairs = sorted(anyrow.keys())
    next_rec = _next_seq(cur, "hospital_demand", "HospitalDemandRecordID", len("HDEM-"))
    month_first = date(year, month, 1).isoformat()

    rows = []
    for key in pairs:
        row = list(season.get(key, anyrow[key]))
        row[col["HospitalDemandRecordID"]] = f"HDEM-{next_rec:08d}"
        next_rec += 1
        row[col["DemandMonth"]] = month_first
        rows.append(row)

    out_name = f"06_hospital_demand_data__gen_{period}.csv"
    _write_csv(LANDING_DIR / out_name, header, rows)
    return {"source_file": out_name, "rows_generated": len(rows), "bad_rows": 0,
            "min_date": date(year, month, 1), "max_date": date(year, month, 1)}


# ---------------------------------------------------------------------------
# 01 master (optional price change -> SCD2 new versions)
# ---------------------------------------------------------------------------
def generate_master(period: str, n_changes: int, header: list[str], col: dict) -> dict:
    src = SOURCE_DIR / MASTER_SRC
    with open(src, encoding="utf-8", newline="") as fh:
        r = csv.reader(fh)
        next(r)
        rows = [row for row in r]
    pick = random.sample(range(len(rows)), min(n_changes, len(rows)))
    ri = col["RecommendedRetailPriceUSD"]
    changed = []
    for i in pick:
        old = float(rows[i][ri])
        rows[i][ri] = f"{round(old * 1.10, 2)}"      # +10%, keeps cost<=wholesale<=RRP
        changed.append(rows[i][col["MedicineID"]])
    out_name = f"01_master_data__gen_{period}.csv"
    _write_csv(LANDING_DIR / out_name, header, rows)
    print(f"  master: changed retail price of {len(changed)} medicines: {changed}")
    return {"source_file": out_name, "rows_generated": len(rows), "bad_rows": 0,
            "min_date": None, "max_date": None}


# ---------------------------------------------------------------------------
def _write_csv(path: Path, header: list[str], rows: list[list[str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")   # match the source files' '\n' endings
        w.writerow(header)
        w.writerows(rows)


def _log_generation(cur, run_id: str, period: str, result: dict) -> None:
    cur.execute(
        "INSERT INTO meta.generation_log "
        "(run_id, period, source_file, rows_generated, bad_rows, min_date, max_date) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s)",
        (run_id, period, result["source_file"], result["rows_generated"],
         result["bad_rows"], result["min_date"], result["max_date"]),
    )


def generate(period: str, price_change: int = 0, bad_rows: int = 0,
             run_id: str | None = None, dsn: str = PG_DSN, seed: int | None = None) -> list[dict]:
    year, month = (int(x) for x in period.split("-"))
    run_id = run_id or "gen_" + datetime.now().strftime("%Y%m%dT%H%M%S")
    if seed is not None:
        random.seed(seed)

    sales_hdr = _read_header(SOURCE_DIR / SALES_SRC);  sales_col = _idx(sales_hdr)
    demand_hdr = _read_header(SOURCE_DIR / DEMAND_SRC); demand_col = _idx(demand_hdr)

    results = []
    with psycopg2.connect(dsn) as conn, conn.cursor() as cur:
        k = _avg_monthly_sales(cur)
        print(f"generate {period}: sales target ~{k} rows, bad_rows={bad_rows}, "
              f"price_change={price_change} (run {run_id})")
        results.append(generate_sales(period, year, month, k, bad_rows, cur, sales_hdr, sales_col))
        results.append(generate_demand(period, year, month, cur, demand_hdr, demand_col))
        if price_change > 0:
            master_hdr = _read_header(SOURCE_DIR / MASTER_SRC)
            results.append(generate_master(period, price_change, master_hdr, _idx(master_hdr)))
        for res in results:
            _log_generation(cur, run_id, period, res)
    for res in results:
        print(f"  wrote {res['source_file']}: {res['rows_generated']} rows "
              f"(+{res['bad_rows']} bad) -> {LANDING_DIR}")
    return results


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Generate one new month of SDI source data.")
    ap.add_argument("--period", required=True, help="month to simulate, YYYY-MM")
    ap.add_argument("--price-change", type=int, default=0)
    ap.add_argument("--bad-rows", type=int, default=0)
    ap.add_argument("--seed", type=int, default=None)
    a = ap.parse_args()
    generate(a.period, a.price_change, a.bad_rows, seed=a.seed)
