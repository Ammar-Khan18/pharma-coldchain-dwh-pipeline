# Data oversampling / generator — method notes (WBS 2.1)

**Goal.** Simulate new business periods so the warehouse and dashboards visibly
update on a refresh, *without* hand-writing fake data and without breaking the
model. New rows are **appended**; history is never replaced.

Code: `generator/generate.py` · DAG: `dags/sdi_generate.py` · log: `meta.generation_log`.

## Method — bootstrap oversampling

Rather than invent values, the generator **resamples real history** and moves it
into a new month. For each new sales / demand row it:

1. **Samples a real row** from the same month-of-year (e.g. a new *January* is
   built from historical Januaries), so seasonality and the real per-medicine,
   per-channel, per-pharmacy and per-hospital mix are preserved. Sampling is with
   replacement (a bootstrap), so the generated distribution matches the source.
2. **Keeps every attribute and amount verbatim** — medicine, pharmacy, hospital,
   channel, prices, quantities, margins, flags. Because these come from a real,
   internally consistent row, **referential integrity holds** (only existing
   `MedicineID` / pharmacy / hospital IDs appear) and the validation rules
   (money formulas, returns, stock balance, …) pass.
3. **Only identifiers and dates are changed.** A new `SalesTransactionID` /
   `HospitalDemandRecordID` continues the existing number sequence (read from the
   ODS), so IDs never collide across refreshes. Sale dates are spread across the
   new month; the batch-expiry date is pushed into the future so nothing is sold
   expired.
4. **Byte-compatible output.** Every column, text format, `GTIN14` leading zero
   and date format matches the source files exactly, so `ingest_api` detects the
   file by its `05_/06_/01_` prefix and validation treats it like real data. The
   file keeps the prefix and adds a `__gen_<period>` suffix, and is written to
   `LANDING_DIR` for the file-watcher / `sdi_ingest` chain to pick up.

**Every refresh** writes a fresh `01_master_data` and **deterministically flips the
`PrescriptionClass` (Rx↔OTC) of 1–2 medicines** (seeded by the refresh month, logged to
`meta.generation_log.presclass_changed`). On the next transform this creates a **new SCD
Type 2 version** in `DimMedicine` (old row closed at the refresh month − 1 day, new current
row from the refresh month's 1st) — `PresClass` and `ProductStatus` are the only SCD2 triggers.

**Optional levers (for the demo):**
- `--price-change N` raises the retail price of *N* medicines 10% in the new `01_master_data`.
  Prices are **Type 1** (overwritten, and copied per sale onto `FactPharmacySales` as
  `MfgCost`/`MRP`/`ListTradePrice`) — they no longer drive SCD2.
- `--bad-rows N` adds *N* deliberately invalid rows (negative price, invalid
  date, missing MedicineID, missing pharmacy, zero quantity) to prove the
  validation layer **rejects** them (they land in `ods.rejected_rows`, not the mart).

## Why this volume — one realistic month per refresh

The source holds **36 months** (2023‑01 → 2025‑12). A refresh simulates **one new
month**, sized from history so it looks like a real month, not a spike:

- **Sales** ≈ the average monthly row count = 500,000 ÷ 36 ≈ **13,900 rows**.
- **Hospital demand** = the full grain for the month = 12 hospitals × 63 medicines
  = **756 rows**.

The demo uses **two refreshes** — **Refresh 1 = 2026‑01**, **Refresh 2 = 2026‑02** —
so the dashboards visibly step forward twice (new revenue months, new SCD2
versions, growing storage) while every number still reconciles.

## Stats — Refresh 1 (2026‑01, `--price-change 3 --bad-rows 5`)

From `meta.generation_log`:

| Generated file | Rows | Bad rows | Date span |
| --- | ---: | ---: | --- |
| `05_pharmacy_sales_data__gen_2026-01.csv` | 13,889 | 5 | 2026‑01‑01 → 2026‑01‑31 |
| `06_hospital_demand_data__gen_2026-01.csv` | 756 | 0 | 2026‑01‑01 |
| `01_master_data__gen_2026-01.csv` | 63 | 0 | — (master) |

**Effect on the warehouse after the chain ran (before → after):**

| Table | Before | After | Δ |
| --- | ---: | ---: | ---: |
| `ods.pharmacy_sales` | 500,000 | 513,894 | +13,894 (13,889 good + 5 bad) |
| `ods.hospital_demand` | 27,216 | 27,972 | +756 |
| `FactPharmacySales` | 500,000 | 513,889 | +13,889 (5 bad rejected) |
| `FactHospitalDemand` | 27,216 | 27,972 | +756 |
| `DimMedicine` rows | 63 | 64+ | new SCD2 version(s) |
| `ods.rejected_rows` | 0 | 5 | +5 (rules S2, S3, S4, S6, S7) |

Each refresh also deterministically flips the `PrescriptionClass` of 1–2 medicines, which
creates a new `DimMedicine` SCD2 version (prices are Type 1 and no longer drive SCD2). Row
counts reconcile: ODS new rows = fact rows loaded + rejected rows, and the Postgres `mart`
matches the DuckDB `sdi` star exactly. For a concrete, fully-verified before/after (the
`2026-02` refresh), see [`oversampled_data/data_dictionary.md`](../oversampled_data/data_dictionary.md) §4.

## How to run

```bash
# via the DAG (drops files in landing, then runs the whole chain automatically)
airflow dags trigger sdi_generate \
    --conf '{"period": "2026-01", "price_change": 3, "bad_rows": 5}'

# or standalone (writes files + logs meta.generation_log only)
python ~/pipeline/generator/generate.py --period 2026-01 --price-change 3 --bad-rows 5
```
