#!/usr/bin/env bash
# Import the Phase-1 SDI dashboards into Grafana via its HTTP API.
# Reads admin credentials from the environment — the password is NEVER hard-coded:
#   export GRAFANA_USER=admin
#   export GRAFANA_PASSWORD='<your admin password>'
#   bash ~/pipeline/bi/grafana/import_dashboards.sh
# Optional: GRAFANA_URL (default http://localhost:3000).
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
: "${GRAFANA_USER:?set GRAFANA_USER (e.g. export GRAFANA_USER=admin)}"
: "${GRAFANA_PASSWORD:?set GRAFANA_PASSWORD (do not hard-code it)}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dashboards"
AUTH=(-u "${GRAFANA_USER}:${GRAFANA_PASSWORD}")
FOLDER_UID="ida-pipeline"
FOLDER_TITLE="IDA Pipeline"

# 1) Ensure the target folder exists (idempotent: ignore "already exists").
curl -sS "${AUTH[@]}" -H 'Content-Type: application/json' \
  -X POST "${GRAFANA_URL}/api/folders" \
  -d "{\"uid\":\"${FOLDER_UID}\",\"title\":\"${FOLDER_TITLE}\"}" >/dev/null 2>&1 || true

# 2) Import each dashboard JSON (wrap it as {dashboard, overwrite, folderUid}).
for f in "${DIR}"/*.json; do
  payload="$(python3 - "$f" "$FOLDER_UID" <<'PY'
import json, sys
model = json.load(open(sys.argv[1], encoding="utf-8"))
model.pop("id", None)
print(json.dumps({"dashboard": model, "overwrite": True, "folderUid": sys.argv[2]}))
PY
)"
  resp="$(curl -sS "${AUTH[@]}" -H 'Content-Type: application/json' \
            -X POST "${GRAFANA_URL}/api/dashboards/db" -d "${payload}")"
  url="$(python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("url") or r)' <<<"$resp")"
  printf '%-32s -> %s%s\n' "$(basename "$f")" "${GRAFANA_URL}" "${url}"
done
