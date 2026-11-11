"""
file_watcher.py  —  the spec's "automated file-watcher" for Phase 1 ingestion.

Watches LANDING_DIR. The moment a *.csv file finishes landing there, it triggers
the `sdi_ingest` Airflow DAG for that file (via the airflow CLI), passing the
file name in the run conf. That is the whole point of the landing zone: drop a
file in, the pipeline picks it up on its own — no manual trigger.

HOW A DROP BECOMES A RUN
    new file in LANDING_DIR
      -> wait until its size stops changing (so we never trigger on a half-copied
         200 MB file)
      -> airflow dags trigger sdi_ingest --conf '{"files": ["<name>"]}'
      -> the DAG COPYs it into ODS and archives it (moving it OUT of LANDING_DIR).

RUN IT (Ubuntu/WSL, venv active):
    python ~/pipeline/ingestion/file_watcher.py
    # leave it running in its own terminal; Ctrl-C to stop.

WHY POLLING (important on WSL)
    This project's landing zone lives under ~/pipeline, which is a symlink onto a
    Windows drive (/mnt/d/...). WSL2 does NOT deliver inotify events for files
    created on /mnt drives, so the normal event-based watchdog Observer never
    fires there. We therefore use watchdog's PollingObserver, which checks the
    folder with stat() on a short interval and works on mounted drives (and on
    native Linux too). Set WATCHER_NATIVE=1 to force the inotify Observer if your
    landing zone is on the native Linux filesystem (faster, event-driven).

Env vars:
    LANDING_DIR     folder to watch       (default: ~/pipeline/landing)
    AIRFLOW_BIN     airflow executable    (default: the one next to this python, else 'airflow')
    WATCHER_NATIVE  '1' = use inotify Observer instead of polling (default: polling)
    WATCHER_POLL_SECONDS  polling interval (default: 2)
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer
from watchdog.observers.polling import PollingObserver

LANDING_DIR = Path(os.environ.get("LANDING_DIR", str(Path.home() / "pipeline" / "landing")))
DAG_ID = "sdi_ingest"


def _airflow_bin() -> str:
    """Find the airflow CLI: explicit env, then next to this interpreter, then PATH."""
    if os.environ.get("AIRFLOW_BIN"):
        return os.environ["AIRFLOW_BIN"]
    candidate = Path(sys.executable).with_name("airflow")
    if candidate.exists():
        return str(candidate)
    return shutil.which("airflow") or "airflow"


def _wait_until_stable(path: Path, quiet_seconds: float = 2.0, timeout: float = 600.0) -> bool:
    """Return True once the file's size has held steady for `quiet_seconds`
    (i.e. the copy finished). Guards against triggering on a partial file."""
    deadline = time.time() + timeout
    last_size, stable_since = -1, None
    while time.time() < deadline:
        try:
            size = path.stat().st_size
        except FileNotFoundError:
            return False                      # moved/removed before it settled
        now = time.time()
        if size == last_size and size > 0:
            if stable_since is None:
                stable_since = now
            elif now - stable_since >= quiet_seconds:
                return True
        else:
            last_size, stable_since = size, None
        time.sleep(0.5)
    return False


def _trigger(path: Path) -> None:
    conf = json.dumps({"files": [path.name]})
    cmd = [_airflow_bin(), "dags", "trigger", DAG_ID, "--conf", conf]
    print(f"[watcher] {path.name} settled -> triggering {DAG_ID} ({conf})", flush=True)
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError as exc:
        print(f"[watcher] ERROR: trigger failed for {path.name}: {exc}", file=sys.stderr, flush=True)


class _LandingHandler(FileSystemEventHandler):
    def _handle(self, raw_path: str, is_dir: bool) -> None:
        if is_dir:
            return
        path = Path(raw_path)
        if path.suffix.lower() != ".csv":
            return
        if _wait_until_stable(path):
            _trigger(path)
        else:
            print(f"[watcher] {path.name} did not settle (moved or timed out); skipped.",
                  flush=True)

    def on_created(self, event):
        self._handle(event.src_path, event.is_directory)

    def on_moved(self, event):               # e.g. a 'cp' that writes tmp then renames
        self._handle(event.dest_path, event.is_directory)


def main() -> None:
    LANDING_DIR.mkdir(parents=True, exist_ok=True)
    if os.environ.get("WATCHER_NATIVE") == "1":
        observer = Observer()
        mode = "inotify"
    else:
        observer = PollingObserver(timeout=float(os.environ.get("WATCHER_POLL_SECONDS", "2")))
        mode = "polling"
    print(f"[watcher] watching {LANDING_DIR} for new *.csv files ({mode}). Ctrl-C to stop.",
          flush=True)
    observer.schedule(_LandingHandler(), str(LANDING_DIR), recursive=False)
    observer.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[watcher] stopping.", flush=True)
        observer.stop()
    observer.join()


if __name__ == "__main__":
    main()
