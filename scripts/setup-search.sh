#!/usr/bin/env bash
# =============================================================================
# setup-search.sh
#
# Creates / updates all Azure AI Search resources needed for the IoT telemetry
# monitoring demo.  Run this AFTER the storage account, IoT Hub, and Azure
# Function have been deployed.
#
# Usage:
#   export SEARCH_SERVICE="my-ai-search-demo"
#   export SEARCH_ADMIN_KEY="YOUR_ADMIN_KEY"
#   export STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=..."
#   bash scripts/setup-search.sh
#
# Requirements: curl, jq (optional but recommended for pretty output)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables
# ---------------------------------------------------------------------------
SEARCH_SERVICE="${SEARCH_SERVICE:?Set SEARCH_SERVICE env var}"
SEARCH_ADMIN_KEY="${SEARCH_ADMIN_KEY:?Set SEARCH_ADMIN_KEY env var}"
STORAGE_CONNECTION_STRING="${STORAGE_CONNECTION_STRING:?Set STORAGE_CONNECTION_STRING env var}"
API_VERSION="2023-11-01"
BASE_URL="https://${SEARCH_SERVICE}.search.windows.net"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
search_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  if [[ -n "$body" ]]; then
    curl -s -X "$method" \
      "${BASE_URL}${path}?api-version=${API_VERSION}" \
      -H "Content-Type: application/json" \
      -H "api-key: ${SEARCH_ADMIN_KEY}" \
      -d "$body"
  else
    curl -s -X "$method" \
      "${BASE_URL}${path}?api-version=${API_VERSION}" \
      -H "api-key: ${SEARCH_ADMIN_KEY}"
  fi
}

log() { echo "[setup-search] $*"; }

# ---------------------------------------------------------------------------
# 1. Create / replace the search index
# ---------------------------------------------------------------------------
log "Creating index: iot-telemetry-index ..."
INDEX_BODY=$(cat "$(dirname "$0")/../search/index-schema.json")
search_request PUT "/indexes/iot-telemetry-index" "$INDEX_BODY"
echo ""
log "Index created (or already up-to-date)."

# ---------------------------------------------------------------------------
# 2. Create the data source pointing at telemetry-processed container
#    (the container written by the Azure Function decoder)
# ---------------------------------------------------------------------------
log "Creating datasource: telemetry-processed-datasource ..."
DATASOURCE_BODY=$(
  jq --arg cs "$STORAGE_CONNECTION_STRING" \
    '.credentials.connectionString = $cs' \
    "$(dirname "$0")/../search/datasource-config.json"
)
search_request POST "/datasources" "$DATASOURCE_BODY"
echo ""
log "Datasource created."

# ---------------------------------------------------------------------------
# 3. Create the indexer
# ---------------------------------------------------------------------------
log "Creating indexer: telemetry-indexer ..."
INDEXER_BODY=$(cat "$(dirname "$0")/../search/indexer-config.json")
search_request POST "/indexers" "$INDEXER_BODY"
echo ""
log "Indexer created."

# ---------------------------------------------------------------------------
# 4. Trigger an immediate indexer run
# ---------------------------------------------------------------------------
log "Triggering indexer run ..."
search_request POST "/indexers/telemetry-indexer/run"
echo ""
log "Indexer run triggered.  Wait ~30 seconds then query to verify."

# ---------------------------------------------------------------------------
# 5. Verify — print document count
# ---------------------------------------------------------------------------
sleep 5
log "Checking document count ..."
COUNT_RESPONSE=$(search_request GET '/indexes/iot-telemetry-index/docs?$count=true&search=*&$top=0')
echo "$COUNT_RESPONSE"
echo ""
log "Done.  If @odata.count is 0, wait a few minutes for the indexer to finish"
log "and then run:"
log "  curl -s '${BASE_URL}/indexes/iot-telemetry-index/docs?\$filter=temperature+gt+30&api-version=${API_VERSION}' -H 'api-key: ${SEARCH_ADMIN_KEY}' | python3 -m json.tool"
