"""
ingest_api.py  —  Phase 1 batch ingestion (raw CSV -> Postgres ODS).

WBS 2.x (batch ingestion layer). Called by the `sdi_ingest` Airflow DAG, and
usable on its own from the command line.

WHAT IT DOES  (one public function: ingest_file(path))
  1. Works out which source a file is, from its name
     (01_* -> ods.master_data, 05_* -> ods.pharmacy_sales, 06_* -> ods.hospital_demand).
  2. Streams it into the matching ODS table with Postgres COPY (psycopg2
     copy_expert) — fast enough for the 500,000-row sales file. Every column
     lands as TEXT; nothing is parsed or cleaned here (that is the transform's job).
  3. Measures start/end time, rows loaded, and success/failure.
  4. Writes ONE row to meta.batch_log for the attempt — on success AND on failure.
  5. Skips a file whose content hash was already loaded successfully (so a
     re-dropped or re-triggered file is never double-loaded), using the
     meta.batch_log.file_hash column added by 02_ods_tables.sql.
  6. Moves the file to ARCHIVE_DIR once it has loaded successfully.

WHY TEXT + APPEND
  The ODS is the raw inbox (see docs/phase1_sdi_design.md section 2). Loading
  every column as text keeps GTIN14 / GLN / SSCC18 leading zeros and precision
  intact (profiling findings P1/P2). Loads append so refresh history is kept;
  the ingestion layer never truncates.

WHERE TO RUN (standalone, Ubuntu/WSL with the venv active)
    python ~/pipeline/ingestion/ingest_api.py ~/pipeline/landing/05_pharmacy_sales_data.csv
  Optional env vars (same convention as serving/publish_mart.py):
    IDA_PG_DSN   psycopg2 DSN           (default: host=localhost ... dbname=ida_staging)
    ARCHIVE_DIR  where loaded files go  (default: ~/pipeline/archive)
"""
import hashlib
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import psycopg2

# Same default DSN as serving/publish_mart.py, overridable with IDA_PG_DSN.
PG_DSN = os.environ.get(
    "IDA_PG_DSN",
    "host=localhost port=5432 dbname=ida_staging user=ida_user password=ida_pass",
)
DEFAULT_ARCHIVE_DIR = os.environ.get(
    "ARCHIVE_DIR", str(Path.home() / "pipeline" / "archive")
)

# Map a file-name prefix to the ODS table it loads into.
# (Only Phase 1 sources: 01 master, 05 pharmacy sales, 06 hospital demand.)
SOURCE_MAP = {
    "01": {"table": "ods.master_data",     "pattern": "01_master_data"},
    "05": {"table": "ods.pharmacy_sales",  "pattern": "05_pharmacy_sales_data"},
    "06": {"table": "ods.hospital_demand", "pattern": "06_hospital_demand_data"},
}

META_COLUMNS = ("etl_batch_id", "source_file", "loaded_at")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def detect_source(path) -> dict:
    """Return {'table':..., 'prefix':...} for a Phase 1 source file, by its name.
    Raises ValueError if the file is not a recognised Phase 1 source."""
    name = Path(path).name
    prefix = name[:2]
    info = SOURCE_MAP.get(prefix)
    if not info or info["pattern"] not in name:
        known = ", ".join(f"{k}_*" for k in SOURCE_MAP)
        raise ValueError(
            f"'{name}' is not a recognised Phase 1 source file (expected one of: {known})."
        )
    return {"table": info["table"], "prefix": prefix}


def file_sha256(path) -> str:
    """Content hash of a file, read in chunks so a 200 MB file fits in memory."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _source_columns(cur, table: str) -> list[str]:
    """The real source columns of an ODS table, in file order, excluding the
    three ETL audit columns. Read from the catalog so we never drift from the DDL."""
    schema, name = table.split(".", 1)
    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = %s AND table_name = %s "
        "ORDER BY ordinal_position",
        (schema, name),
    )
    cols = [r[0] for r in cur.fetchall()]
    if not cols:
        raise RuntimeError(
            f"Table {table} does not exist. Run sql/postgres/02_ods_tables.sql first."
        )
    return [c for c in cols if c not in META_COLUMNS]


def _already_loaded(cur, file_hash: str) -> bool:
    """True if this exact file content was loaded successfully before."""
    cur.execute(
        "SELECT 1 FROM meta.batch_log "
        "WHERE file_hash = %s AND status = 'SUCCESS' LIMIT 1",
        (file_hash,),
    )
    return cur.fetchone() is not None


def _write_batch_log(conn, row: dict) -> None:
    """Insert exactly one row into meta.batch_log (its own committed transaction)."""
    cols = [
        "etl_batch_id", "dag_id", "task_id", "source_file", "target_table",
        "file_size_mb", "started_at", "finished_at", "duration_sec",
        "rows_read", "rows_loaded", "rows_rejected", "status",
        "error_message", "file_hash",
    ]
    placeholders = ", ".join(["%s"] * len(cols))
    with conn, conn.cursor() as cur:
        cur.execute(
            f"INSERT INTO meta.batch_log ({', '.join(cols)}) VALUES ({placeholders})",
            [row.get(c) for c in cols],
        )


def _archive(path, archive_dir: str) -> str:
    """Move a processed file into ARCHIVE_DIR, keeping it unique with a timestamp."""
    archive = Path(archive_dir)
    archive.mkdir(parents=True, exist_ok=True)
    src = Path(path)
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    dest = archive / f"{src.stem}.{stamp}{src.suffix}"
    os.replace(src, dest)       # atomic on the same filesystem
    return str(dest)


# ---------------------------------------------------------------------------
# the one public function
# ---------------------------------------------------------------------------
def ingest_file(
    path,
    etl_batch_id: str | None = None,
    dsn: str = PG_DSN,
    archive_dir: str = DEFAULT_ARCHIVE_DIR,
    dag_id: str | None = None,
    task_id: str | None = None,
) -> dict:
    """Load ONE Phase 1 CSV file into its ODS table and log the attempt.

    Returns a result dict:
        {status: SUCCESS|FAILED|SKIPPED, source_file, target_table,
         rows_loaded, duration_sec, archived_to, error}

    status meanings:
        SUCCESS  rows were appended and the file was archived.
        SKIPPED  the identical file was already loaded; nothing changed.
        FAILED   the load errored; the data transaction was rolled back and a
                 FAILED row was written to meta.batch_log. Re-raises so Airflow
                 marks the task failed and retries.
    """
    path = str(path)
    source_file = Path(path).name
    etl_batch_id = etl_batch_id or "manual_" + datetime.now().strftime("%Y%m%dT%H%M%S")

    target_table = detect_source(path)["table"]       # may raise ValueError -> caught below
    file_size_mb = round(os.path.getsize(path) / 1_048_576, 2)
    file_hash = file_sha256(path)
    started_at = datetime.now(timezone.utc)
    t0 = time.time()

    conn = psycopg2.connect(dsn)
    try:
        # --- skip files that were already loaded successfully -----------------
        with conn.cursor() as cur:
            if _already_loaded(cur, file_hash):
                conn.rollback()
                archived_to = _archive(path, archive_dir)
                print(f"SKIP  {source_file}: identical file already loaded "
                      f"(hash {file_hash[:12]}…). Moved to {archived_to}.")
                return {
                    "status": "SKIPPED", "source_file": source_file,
                    "target_table": target_table, "rows_loaded": 0,
                    "duration_sec": round(time.time() - t0, 3),
                    "archived_to": archived_to, "error": None,
                }

        # --- the load: COPY the CSV into the ODS table as text ----------------
        with conn:                                     # one transaction; commits on exit
            with conn.cursor() as cur:
                src_cols = _source_columns(cur, target_table)
                col_list = ", ".join(f'"{c}"' for c in src_cols)
                copy_sql = (
                    f"COPY {target_table} ({col_list}) FROM STDIN "
                    f"WITH (FORMAT csv, HEADER true)"
                )
                with open(path, "r", encoding="utf-8") as fh:
                    cur.copy_expert(copy_sql, fh)
                rows_loaded = cur.rowcount             # rows COPY actually appended
                # Stamp the audit columns on the rows we just appended. Loads are
                # serialized and append-only, so the only rows with a NULL
                # etl_batch_id are the ones from this COPY, inside this txn.
                cur.execute(
                    f"UPDATE {target_table} "
                    f"SET etl_batch_id = %s, source_file = %s "
                    f"WHERE etl_batch_id IS NULL",
                    (etl_batch_id, source_file),
                )
        duration_sec = round(time.time() - t0, 3)
        finished_at = datetime.now(timezone.utc)

        _write_batch_log(conn, {
            "etl_batch_id": etl_batch_id, "dag_id": dag_id, "task_id": task_id,
            "source_file": source_file, "target_table": target_table,
            "file_size_mb": file_size_mb, "started_at": started_at,
            "finished_at": finished_at, "duration_sec": duration_sec,
            "rows_read": rows_loaded, "rows_loaded": rows_loaded,
            "rows_rejected": 0, "status": "SUCCESS",
            "error_message": None, "file_hash": file_hash,
        })
        archived_to = _archive(path, archive_dir)
        print(f"OK    {source_file}: {rows_loaded:,} rows -> {target_table} "
              f"in {duration_sec:.3f}s. Moved to {archived_to}.")
        return {
            "status": "SUCCESS", "source_file": source_file,
            "target_table": target_table, "rows_loaded": rows_loaded,
            "duration_sec": duration_sec, "archived_to": archived_to, "error": None,
        }

    except Exception as exc:
        conn.rollback()                                # no half-loaded data
        duration_sec = round(time.time() - t0, 3)
        # Still record the failed attempt — one row, as the spec requires.
        try:
            _write_batch_log(conn, {
                "etl_batch_id": etl_batch_id, "dag_id": dag_id, "task_id": task_id,
                "source_file": source_file,
                "target_table": locals().get("target_table"),
                "file_size_mb": locals().get("file_size_mb"),
                "started_at": started_at,
                "finished_at": datetime.now(timezone.utc),
                "duration_sec": duration_sec,
                "rows_read": None, "rows_loaded": 0, "rows_rejected": None,
                "status": "FAILED", "error_message": str(exc),
                "file_hash": locals().get("file_hash"),
            })
        except Exception as log_exc:                   # logging must not hide the real error
            print(f"WARN  could not write FAILED batch_log row: {log_exc}", file=sys.stderr)
        print(f"FAIL  {source_file}: {exc}", file=sys.stderr)
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: python ingest_api.py <path-to-csv> [<path-to-csv> ...]")
    batch = "manual_" + datetime.now().strftime("%Y%m%dT%H%M%S")
    for arg in sys.argv[1:]:
        ingest_file(arg, etl_batch_id=batch)
