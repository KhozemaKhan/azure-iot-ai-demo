#!/usr/bin/env bash
# setup-search.sh — Create (or recreate) Azure AI Search resources for the IoT telemetry demo.
#
# Usage:
#   export SEARCH_ENDPOINT="https://<your-service>.search.windows.net"
#   export SEARCH_ADMIN_KEY="<your-admin-key>"
#   export STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;EndpointSuffix=core.windows.net"
#   export STORAGE_CONTAINER="telemetry-jsonlines"   # container with plain JSON-lines blobs
#   bash scripts/setup-search.sh

set -euo pipefail

: "${SEARCH_ENDPOINT:?Set SEARCH_ENDPOINT}"
: "${SEARCH_ADMIN_KEY:?Set SEARCH_ADMIN_KEY}"
: "${STORAGE_CONNECTION_STRING:?Set STORAGE_CONNECTION_STRING}"
: "${STORAGE_CONTAINER:=telemetry-jsonlines}"

API_VERSION="2023-11-01"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEARCH_DIR="${SCRIPT_DIR}/../search"

auth_header="api-key: ${SEARCH_ADMIN_KEY}"
content_header="Content-Type: application/json"

# ---------------------------------------------------------------------------
# Helper: pretty-print result
# ---------------------------------------------------------------------------
check_response() {
  local step="$1"
  local http_code="$2"
  local body="$3"
  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    echo "✅  ${step} succeeded (HTTP ${http_code})"
  else
    echo "❌  ${step} failed (HTTP ${http_code})"
    echo "${body}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Step 1 – Delete existing resources (clean-slate reindex)
# ---------------------------------------------------------------------------
echo ""
echo "── Step 1: Deleting existing indexer, datasource, and index (if any) ──"

for resource in "indexers/telemetry-indexer" "datasources/telemetry-datasource" "indexes/iot-telemetry-index"; do
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    "${SEARCH_ENDPOINT}/${resource}?api-version=${API_VERSION}" \
    -H "${auth_header}")
  if [[ "${http_code}" == "204" || "${http_code}" == "404" ]]; then
    echo "  Removed (or not present): ${resource}"
  else
    echo "  Warning: DELETE ${resource} returned HTTP ${http_code}"
  fi
done

# ---------------------------------------------------------------------------
# Step 2 – Create index
# ---------------------------------------------------------------------------
echo ""
echo "── Step 2: Creating index ──"
response=$(curl -s -w "\n%{http_code}" -X POST \
  "${SEARCH_ENDPOINT}/indexes?api-version=${API_VERSION}" \
  -H "${auth_header}" \
  -H "${content_header}" \
  -d @"${SEARCH_DIR}/index-schema.json")
body=$(echo "${response}" | head -n -1)
http_code=$(echo "${response}" | tail -n1)
check_response "Create index" "${http_code}" "${body}"

# ---------------------------------------------------------------------------
# Step 3 – Create datasource (inject the real connection string)
# ---------------------------------------------------------------------------
echo ""
echo "── Step 3: Creating datasource ──"
datasource_payload=$(cat "${SEARCH_DIR}/datasource-config.json" \
  | sed "s|<YOUR_STORAGE_ACCOUNT>|placeholder|g" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
import os
data['credentials']['connectionString'] = os.environ['STORAGE_CONNECTION_STRING']
data['container']['name'] = os.environ.get('STORAGE_CONTAINER', 'telemetry-jsonlines')
print(json.dumps(data))
")
response=$(curl -s -w "\n%{http_code}" -X POST \
  "${SEARCH_ENDPOINT}/datasources?api-version=${API_VERSION}" \
  -H "${auth_header}" \
  -H "${content_header}" \
  -d "${datasource_payload}")
body=$(echo "${response}" | head -n -1)
http_code=$(echo "${response}" | tail -n1)
check_response "Create datasource" "${http_code}" "${body}"

# ---------------------------------------------------------------------------
# Step 4 – Create indexer
# ---------------------------------------------------------------------------
echo ""
echo "── Step 4: Creating indexer ──"
response=$(curl -s -w "\n%{http_code}" -X POST \
  "${SEARCH_ENDPOINT}/indexers?api-version=${API_VERSION}" \
  -H "${auth_header}" \
  -H "${content_header}" \
  -d @"${SEARCH_DIR}/indexer-config.json")
body=$(echo "${response}" | head -n -1)
http_code=$(echo "${response}" | tail -n1)
check_response "Create indexer" "${http_code}" "${body}"

# ---------------------------------------------------------------------------
# Step 5 – Trigger an immediate run
# ---------------------------------------------------------------------------
echo ""
echo "── Step 5: Triggering indexer run ──"
response=$(curl -s -w "\n%{http_code}" -X POST \
  "${SEARCH_ENDPOINT}/indexers/telemetry-indexer/run?api-version=${API_VERSION}" \
  -H "${auth_header}")
body=$(echo "${response}" | head -n -1)
http_code=$(echo "${response}" | tail -n1)
check_response "Run indexer" "${http_code}" "${body}"

echo ""
echo "All steps completed.  Wait ~1 minute, then verify with:"
echo ""
echo "  curl -s \"${SEARCH_ENDPOINT}/indexers/telemetry-indexer/status?api-version=${API_VERSION}\" \\"
echo "       -H \"api-key: \${SEARCH_ADMIN_KEY}\" | python3 -m json.tool"
echo ""
echo "  curl -s \"${SEARCH_ENDPOINT}/indexes/iot-telemetry-index/docs?api-version=${API_VERSION}&search=*&\$top=5\" \\"
echo "       -H \"api-key: \${SEARCH_ADMIN_KEY}\" | python3 -m json.tool"
