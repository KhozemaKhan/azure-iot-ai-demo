#!/usr/bin/env bash
# validate.sh
#
# End-to-end validation for the IoT Hub → Event Hub → Azure Function →
# Blob (telemetry-decoded) → Azure AI Search pipeline.
#
# Checks:
#   1. telemetry-decoded container exists and contains blobs
#   2. AI Search index has documents with non-null temperature/humidity
#   3. Filter  temperature gt 30  returns results
#   4. (Optional) Triggers Logic App with a high-temperature payload
#
# Usage
# ─────
#   chmod +x scripts/validate.sh
#   RESOURCE_GROUP=rg-learn-ai \
#   STORAGE_ACCOUNT=stlearnai \
#   SEARCH_SERVICE=learn-ai-aisearch \
#   SEARCH_ADMIN_KEY=<your-admin-key> \
#   LOGIC_APP_URL=<full-logic-app-callback-url-with-sig> \
#   ./scripts/validate.sh

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:?Set STORAGE_ACCOUNT}"
SEARCH_SERVICE="${SEARCH_SERVICE:?Set SEARCH_SERVICE}"
SEARCH_ADMIN_KEY="${SEARCH_ADMIN_KEY:?Set SEARCH_ADMIN_KEY}"
LOGIC_APP_URL="${LOGIC_APP_URL:-}"   # optional
SEARCH_API_VERSION="${SEARCH_API_VERSION:-2024-07-01}"
SEARCH_ENDPOINT="https://${SEARCH_SERVICE}.search.windows.net"

PASS=0
FAIL=0

pass() { echo "  ✅ PASS: $*"; ((PASS++)) || true; }
fail() { echo "  ❌ FAIL: $*"; ((FAIL++)) || true; }

echo "=== azure-iot-ai-demo: validate ==="
echo ""

# ── 1. Check telemetry-decoded container has blobs ────────────────────────────
echo "▶ [1] Checking telemetry-decoded container for blobs..."

BLOB_COUNT=$(az storage blob list \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "telemetry-decoded" \
  --auth-mode login \
  --output json 2>/dev/null | jq length || echo "0")

if [[ "$BLOB_COUNT" -gt 0 ]]; then
  pass "telemetry-decoded container has $BLOB_COUNT blob(s)"
else
  fail "telemetry-decoded container is empty – is the simulator running and Function deployed?"
fi

# ── 2. Check index has non-null temperature documents ─────────────────────────
echo "▶ [2] Checking AI Search index for documents with non-null temperature..."

ALL_DOCS=$(curl -sf \
  "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index/docs?\$top=10&api-version=${SEARCH_API_VERSION}" \
  -H "api-key: ${SEARCH_ADMIN_KEY}")

DOC_COUNT=$(echo "$ALL_DOCS" | jq '."@odata.count" // (.value | length)')
NON_NULL=$(echo "$ALL_DOCS" | jq '[.value[] | select(.temperature != null)] | length')

if [[ "$NON_NULL" -gt 0 ]]; then
  pass "Index has $DOC_COUNT total document(s), $NON_NULL with non-null temperature"
else
  fail "All $DOC_COUNT document(s) have null temperature – indexer or parsingMode issue"
  echo "       Raw docs:"
  echo "$ALL_DOCS" | jq '.value[] | {id, temperature, humidity}' 2>/dev/null || true
fi

# ── 3. Query temperature gt 30 ────────────────────────────────────────────────
echo "▶ [3] Querying temperature gt 30..."

HOT_DOCS=$(curl -sf \
  "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index/docs?\$filter=temperature+gt+30&\$orderby=enqueuedTimeUtc+desc&\$top=5&api-version=${SEARCH_API_VERSION}" \
  -H "api-key: ${SEARCH_ADMIN_KEY}")

HOT_COUNT=$(echo "$HOT_DOCS" | jq '.value | length')

if [[ "$HOT_COUNT" -gt 0 ]]; then
  pass "Found $HOT_COUNT document(s) with temperature > 30:"
  echo "$HOT_DOCS" | jq '.value[] | {id, deviceId, temperature, enqueuedTimeUtc}' 2>/dev/null || true
else
  fail "No documents with temperature > 30 found. Check simulator is sending data."
fi

# ── 4. (Optional) Trigger Logic App with a high-temp payload ─────────────────
if [[ -n "$LOGIC_APP_URL" ]]; then
  echo "▶ [4] Triggering Logic App with temperature=35.5..."

  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "$LOGIC_APP_URL" \
    -H "Content-Type: application/json" \
    -d '{
      "messageId": 9999,
      "deviceId": "validate-script",
      "temperature": 35.5,
      "humidity": 60.2,
      "enqueuedTime": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
    }')

  if [[ "$HTTP_STATUS" =~ ^2 ]]; then
    pass "Logic App responded with HTTP $HTTP_STATUS"
  else
    fail "Logic App responded with HTTP $HTTP_STATUS"
  fi
else
  echo "   [4] Skipped (set LOGIC_APP_URL to test agent → Logic App trigger)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "  PASS: $PASS   FAIL: $FAIL"
echo "═══════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then
  echo "See TROUBLESHOOTING in README.md for remediation steps."
  exit 1
fi
