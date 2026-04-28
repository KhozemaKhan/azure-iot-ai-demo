#!/usr/bin/env bash
# validate-search.sh
# Queries Azure AI Search to validate that temperature data has been indexed.
#
# Usage:
#   ./scripts/validate-search.sh \
#       --search-service <search-service-name> \   # e.g. learn-ai-aisearch
#       --api-key        <admin-or-query-api-key> \
#       [--index-name    <index-name>]              # default: iot-telemetry-index

set -euo pipefail

INDEX_NAME="iot-telemetry-index"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --search-service) SEARCH_SERVICE="$2"; shift 2 ;;
    --api-key)        API_KEY="$2";        shift 2 ;;
    --index-name)     INDEX_NAME="$2";     shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

: "${SEARCH_SERVICE:?'--search-service is required'}"
: "${API_KEY:?'--api-key is required'}"

BASE_URL="https://${SEARCH_SERVICE}.search.windows.net/indexes/${INDEX_NAME}/docs"
HEADERS=(-H "Content-Type: application/json" -H "api-key: ${API_KEY}")

echo "=== 1) Total documents in index ==="
curl -s "${BASE_URL}?\$count=true&\$top=0&api-version=2023-11-01" \
  "${HEADERS[@]}" | python3 -m json.tool

echo ""
echo "=== 2) Latest 5 documents (sorted by enqueuedTimeUtc desc) ==="
curl -s "${BASE_URL}?\$orderby=enqueuedTimeUtc%20desc&\$top=5&api-version=2023-11-01" \
  "${HEADERS[@]}" | python3 -m json.tool

echo ""
echo "=== 3) Documents with temperature > 30 ==="
FILTER="\$filter=temperature%20gt%2030"
RESULT=$(curl -s "${BASE_URL}?${FILTER}&\$count=true&\$orderby=enqueuedTimeUtc%20desc&api-version=2023-11-01" \
  "${HEADERS[@]}")

echo "$RESULT" | python3 -m json.tool

COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('@odata.count', 0))" 2>/dev/null || echo 0)

echo ""
if [[ "$COUNT" -gt 0 ]]; then
  echo "✅ SUCCESS: Found $COUNT document(s) with temperature > 30."
  echo "   The agent should now be able to trigger the Logic App for high-temperature alerts."
else
  echo "⚠️  No documents with temperature > 30 found."
  echo "   Check that:"
  echo "   1. The ASA job is Running (./scripts/start-asa.sh)"
  echo "   2. The IoT simulator is sending data"
  echo "   3. The AI Search indexer has run (Portal → Indexers → Run)"
fi
