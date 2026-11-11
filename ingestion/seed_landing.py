"""
seed_landing.py  —  seed the initial Phase 1 load.

Copies the three Phase 1 source CSVs from SOURCE_DIR into LANDING_DIR so the
file-watcher (or a manual DAG trigger) picks them up, exactly as if they had
just arrived. Use this for the very first load and for demo refreshes.

    01_master_data.csv
    05_pharmacy_sales_data.csv
    06_hospital_demand_data.csv

RUN (Ubuntu/WSL, venv active):
    python ~/pipeline/ingestion/seed_landing.py

Env vars:
    SOURCE_DIR    where the master CSVs live  (default: ~/pipeline/data)
    LANDING_DIR   the landing zone to fill    (default: ~/pipeline/landing)
"""
import os
import shutil
import sys
from pathlib import Path

SOURCE_DIR = Path(os.environ.get("SOURCE_DIR", str(Path.home() / "pipeline" / "data")))
LANDING_DIR = Path(os.environ.get("LANDING_DIR", str(Path.home() / "pipeline" / "landing")))

PHASE1_FILES = [
    "01_master_data.csv",
    "05_pharmacy_sales_data.csv",
    "06_hospital_demand_data.csv",
]


def seed() -> list[Path]:
    LANDING_DIR.mkdir(parents=True, exist_ok=True)
    copied = []
    for name in PHASE1_FILES:
        src = SOURCE_DIR / name
        if not src.exists():
            print(f"MISSING  {src} — skipped", file=sys.stderr)
            continue
        dest = LANDING_DIR / name
        shutil.copy2(src, dest)              # copy, so the master data stays in SOURCE_DIR
        size_mb = dest.stat().st_size / 1_048_576
        print(f"SEEDED   {name:32s} -> {dest}  ({size_mb:.1f} MB)")
        copied.append(dest)
    print(f"\nSeeded {len(copied)} file(s) into {LANDING_DIR}.")
    return copied


if __name__ == "__main__":
    seed()
