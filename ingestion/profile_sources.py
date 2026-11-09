"""
profile_sources.py  -  WBS 1.4 Source data profiling
------------------------------------------------------
Reads the 7 source CSV files and writes a Markdown report describing:
  * size of each file (rows, columns, MB)
  * every column: data type, empty values, distinct values, min/max, examples
  * whether each file's primary key is really unique
  * date ranges (to confirm the 2023-2025 coverage)
  * suspicious values (negative / zero prices and quantities)
  * relationships between files (IDs in one file that are missing from the other)

Run (inside WSL, with the venv active):
    python ~/pipeline/ingestion/profile_sources.py

Output:
    ~/pipeline/docs/data_profiling_report.md
"""

import argparse
import glob
import os
import time

import pandas as pd

# Primary keys as described in the project spec (file prefix -> key columns)
EXPECTED_PK = {
    "01": ["MedicineID"],
    "02": ["ManufacturingOrderID"],
    "03": ["ShipmentID", "LineNo"],
    "04": ["InventorySnapshotID"],
    "05": ["SalesTransactionID"],
    "06": ["HospitalDemandRecordID"],
    "07": ["SensorReadingID"],
}

# Words in a column name that suggest a value must never be negative
NON_NEGATIVE_HINTS = ("price", "cost", "qty", "quantity",
                      "amount", "revenue", "units", "value")
DATE_HINTS = ("date", "time", "timestamp")


def md_escape(value) -> str:
    """Make a value safe to put inside a Markdown table cell."""
    text = str(value)
    return text.replace("|", "\\|").replace("\n", " ")[:60]


def looks_like_date(col: str) -> bool:
    return any(h in col.lower() for h in DATE_HINTS)


def profile_column(series: pd.Series) -> dict:
    total = len(series)
    nulls = int(series.isna().sum())
    info = {
        "dtype": str(series.dtype),
        "nulls": nulls,
        "null_pct": round(100 * nulls / total, 2) if total else 0,
        "distinct": int(series.nunique(dropna=True)),
        "min": "",
        "max": "",
        "examples": ", ".join(md_escape(v) for v in series.dropna().unique()[:3]),
        "notes": [],
    }

    if pd.api.types.is_numeric_dtype(series):
        if series.notna().any():
            info["min"] = series.min()
            info["max"] = series.max()
        if any(h in series.name.lower() for h in NON_NEGATIVE_HINTS):
            neg = int((series < 0).sum())
            zero = int((series == 0).sum())
            if neg:
                info["notes"].append(f"{neg:,} negative")
            if zero:
                info["notes"].append(f"{zero:,} zero")
    elif looks_like_date(series.name):
        parsed = pd.to_datetime(series, errors="coerce")
        bad = int(parsed.isna().sum()) - nulls
        if parsed.notna().any():
            info["min"] = parsed.min()
            info["max"] = parsed.max()
        if bad > 0:
            info["notes"].append(f"{bad:,} unparseable dates")
        info["dtype"] += " (date-like)"

    if info["distinct"] == 1:
        info["notes"].append("constant column")
    return info


def check_primary_key(df: pd.DataFrame, prefix: str) -> str:
    keys = EXPECTED_PK.get(prefix)
    if not keys:
        return "No expected key defined."
    missing = [k for k in keys if k not in df.columns]
    if missing:
        return f"**Key column(s) not found:** {', '.join(missing)} - check the real column names."
    dupes = int(df.duplicated(subset=keys).sum())
    null_keys = int(df[keys].isna().any(axis=1).sum())
    status = "UNIQUE - OK" if dupes == 0 and null_keys == 0 else "PROBLEM"
    return (f"`{' + '.join(keys)}` -> {status} "
            f"(duplicate keys: {dupes:,}, rows with empty key: {null_keys:,})")


def relationship_checks(frames: dict) -> list:
    """For every *ID column shared by two files, find the 'parent' file where the ID is
    unique and count child values that do not exist in the parent (orphans)."""
    id_cols = {}
    for name, df in frames.items():
        for col in df.columns:
            if col.lower().endswith("id"):
                id_cols.setdefault(col, []).append(name)

    rows = []
    for col, files in sorted(id_cols.items()):
        if len(files) < 2:
            continue
        parents = [f for f in files if frames[f][col].dropna().is_unique]
        if not parents:
            rows.append((col, "-", ", ".join(files), "-",
                        "no file has this ID as a unique key"))
            continue
        parent = parents[0]
        parent_values = set(frames[parent][col].dropna().unique())
        for child in files:
            if child == parent:
                continue
            child_values = frames[child][col].dropna()
            orphans = int((~child_values.isin(parent_values)).sum())
            verdict = "OK" if orphans == 0 else "ORPHANS FOUND"
            rows.append((col, parent, child, f"{orphans:,}", verdict))
    return rows


def main():
    parser = argparse.ArgumentParser(
        description="Profile the 7 source CSV files.")
    parser.add_argument(
        "--source", default=os.path.expanduser("~/pipeline/data"))
    parser.add_argument(
        "--out", default=os.path.expanduser("~/pipeline/docs/data_profiling_report.md"))
    args = parser.parse_args()

    files = sorted(glob.glob(os.path.join(args.source, "0*_*.csv")))
    if not files:
        raise SystemExit(f"No CSV files like 01_*.csv found in {args.source}")

    frames, lines, summary = {}, [], []
    lines.append("# Source data profiling report (WBS 1.4)\n")
    lines.append(
        f"Generated: {time.strftime('%Y-%m-%d %H:%M')} from `{args.source}`\n")

    for path in files:
        name = os.path.basename(path)
        prefix = name[:2]
        start = time.time()
        print(f"Reading {name} ...", flush=True)
        df = pd.read_csv(path, low_memory=False)
        secs = time.time() - start
        frames[name] = df

        size_mb = os.path.getsize(path) / 1_048_576
        dup_rows = int(df.duplicated().sum())
        summary.append(
            (name, len(df), len(df.columns), size_mb, dup_rows, secs))

        lines.append(f"\n## {name}\n")
        lines.append(f"- Rows: **{len(df):,}**  |  Columns: **{len(df.columns)}**  |  "
                     f"File size: {size_mb:.1f} MB  |  Read time: {secs:.1f} s")
        lines.append(f"- Fully duplicated rows: {dup_rows:,}")
        lines.append(f"- Primary key: {check_primary_key(df, prefix)}\n")
        lines.append(
            "| Column | Type | Empty | Empty % | Distinct | Min | Max | Examples | Notes |")
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for col in df.columns:
            c = profile_column(df[col])
            lines.append(
                f"| {md_escape(col)} | {c['dtype']} | {c['nulls']:,} | {c['null_pct']} | "
                f"{c['distinct']:,} | {md_escape(c['min'])} | {md_escape(c['max'])} | "
                f"{c['examples']} | {'; '.join(c['notes'])} |"
            )

    # Overview table goes near the top of the report
    overview = ["\n## Overview\n",
                "| File | Rows | Columns | Size (MB) | Duplicate rows | Read time (s) |",
                "|---|---|---|---|---|---|"]
    for name, rows, cols, mb, dups, secs in summary:
        overview.append(
            f"| {name} | {rows:,} | {cols} | {mb:.1f} | {dups:,} | {secs:.1f} |")
    lines[2:2] = overview

    lines.append("\n## Relationships between files\n")
    lines.append("An orphan is an ID in the child file that does not exist in the parent file. "
                 "Orphans must be handled by validation rules before loading facts.\n")
    lines.append(
        "| ID column | Parent file (ID unique) | Child file | Orphan rows | Result |")
    lines.append("|---|---|---|---|---|")
    for row in relationship_checks(frames):
        lines.append("| " + " | ".join(md_escape(v) for v in row) + " |")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    print("\nSummary")
    for name, rows, cols, mb, dups, secs in summary:
        print(f"  {name:40s} {rows:>10,} rows  {cols:>3} cols  {mb:7.1f} MB")
    print(f"\nReport written to {args.out}")


if __name__ == "__main__":
    main()
