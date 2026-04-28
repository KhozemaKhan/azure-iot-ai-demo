#!/usr/bin/env bash
# setup-search.sh
# Creates / updates the AI Search index, datasource, and indexer.
#
# Usage:
#   ./scripts/setup-search.sh \
#       --search-service   <search-service-name> \
#       --admin-api-key    <admin-api-key> \
#       --storage-conn-str "<storage-account-connection-string>"
#
# Security note: pass the storage connection string via a variable read from
# an environment file or secret manager rather than inline on the command line
# to avoid it appearing in shell history. Example:
#   read -rs CONN < /run/secrets/storage_conn && \
#   ./scripts/setup-search.sh --storage-conn-str "$CONN" ...

set -euo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --search-service)   SEARCH_SERVICE="$2";   shift 2 ;;
    --admin-api-key)    ADMIN_API_KEY="$2";    shift 2 ;;
    --storage-conn-str) STORAGE_CONN_STR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

: "${SEARCH_SERVICE:?'--search-service is required'}"
: "${ADMIN_API_KEY:?'--admin-api-key is required'}"
: "${STORAGE_CONN_STR:?'--storage-conn-str is required'}"

BASE_URL="https://${SEARCH_SERVICE}.search.windows.net"
HEADERS=(-H "Content-Type: application/json" -H "api-key: ${ADMIN_API_KEY}")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEARCH_DIR="$SCRIPT_DIR/../search"

echo "=== 1) Creating / updating index ==="
curl -sf -X PUT \
  "${BASE_URL}/indexes/iot-telemetry-index?api-version=2023-11-01" \
  "${HEADERS[@]}" \
  -d @"$SEARCH_DIR/index.json" | python3 -m json.tool

echo ""
echo "=== 2) Creating / updating datasource ==="
# Substitute the connection string placeholder
DS_BODY=$(sed "s|<YOUR_STORAGE_ACCOUNT_CONNECTION_STRING>|${STORAGE_CONN_STR}|g" \
  "$SEARCH_DIR/datasource.json")

curl -sf -X PUT \
  "${BASE_URL}/datasources/iot-telemetry-datasource?api-version=2023-11-01" \
  "${HEADERS[@]}" \
  -d "$DS_BODY" | python3 -m json.tool

echo ""
echo "=== 3) Creating / updating indexer ==="
curl -sf -X PUT \
  "${BASE_URL}/indexers/iot-telemetry-indexer?api-version=2023-11-01" \
  "${HEADERS[@]}" \
  -d @"$SEARCH_DIR/indexer.json" | python3 -m json.tool

echo ""
echo "=== 4) Resetting and running indexer ==="
curl -sf -X POST \
  "${BASE_URL}/indexers/iot-telemetry-indexer/reset?api-version=2023-11-01" \
  "${HEADERS[@]}" -d ''

curl -sf -X POST \
  "${BASE_URL}/indexers/iot-telemetry-indexer/run?api-version=2023-11-01" \
  "${HEADERS[@]}" -d ''

echo "Indexer reset and run triggered."
echo ""
echo "=== Done. Wait ~1 minute then run ./scripts/validate-search.sh to verify. ==="
