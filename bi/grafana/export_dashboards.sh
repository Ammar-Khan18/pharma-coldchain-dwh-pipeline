#!/usr/bin/env bash
# Export the Phase-1 SDI dashboards FROM a running Grafana back into
# bi/grafana/dashboards/*.json (the inverse of import_dashboards.sh).
# Use this after editing a dashboard in the Grafana UI so the repo copy matches.
#
# Reads admin credentials from the environment — never hard-code the password:
#   export GRAFANA_USER=admin
#   export GRAFANA_PASSWORD='<your admin password>'
#   bash ~/pipeline/bi/grafana/export_dashboards.sh
# Optional: GRAFANA_URL (default http://localhost:3000).
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
: "${GRAFANA_USER:?set GRAFANA_USER (e.g. export GRAFANA_USER=admin)}"
: "${GRAFANA_PASSWORD:?set GRAFANA_PASSWORD (do not hard-code it)}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dashboards"
AUTH=(-u "${GRAFANA_USER}:${GRAFANA_PASSWORD}")

# uid -> output filename
declare -A DASHBOARDS=(
  [sdi-batch-ingestion]=sdi_batch_ingestion.json
  [sdi-data-quality]=sdi_data_quality.json
  [sdi-query-performance]=sdi_query_performance.json
  [sdi-storage]=sdi_storage.json
)

for uid in "${!DASHBOARDS[@]}"; do
  out="${DIR}/${DASHBOARDS[$uid]}"
  resp="$(curl -sS "${AUTH[@]}" "${GRAFANA_URL}/api/dashboards/uid/${uid}")"
  # Keep only the dashboard model; strip the volatile "id" and "version".
  python3 - "$resp" "$out" <<'PY'
import json, sys
resp = json.loads(sys.argv[1])
model = resp.get("dashboard", resp)
model.pop("id", None)
model.pop("version", None)
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(model, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print(f"exported {model.get('uid')} -> {sys.argv[2]}")
PY
done
