#!/usr/bin/env bash
# deploy.sh
#
# End-to-end deployment script for the IoT Hub → Event Hub → Azure Function →
# Blob (telemetry-decoded) → Azure AI Search pipeline.
#
# Prerequisites
# ─────────────
#   • Azure CLI (az) installed and logged in  (az login)
#   • jq  installed
#   • Azure Functions Core Tools (func) installed  (for 'func azure functionapp publish')
#   • Resource group and IoT Hub already exist
#
# Usage
# ─────
#   chmod +x scripts/deploy.sh
#   RESOURCE_GROUP=rg-learn-ai \
#   IOTHUB_NAME=learn-ai-iothub \
#   STORAGE_ACCOUNT=stlearnai \
#   SEARCH_SERVICE=learn-ai-aisearch \
#   SEARCH_ADMIN_KEY=<your-admin-key> \
#   ./scripts/deploy.sh

set -euo pipefail

# ── Configuration (override via environment variables) ────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
IOTHUB_NAME="${IOTHUB_NAME:?Set IOTHUB_NAME}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:?Set STORAGE_ACCOUNT}"
SEARCH_SERVICE="${SEARCH_SERVICE:?Set SEARCH_SERVICE}"
SEARCH_ADMIN_KEY="${SEARCH_ADMIN_KEY:?Set SEARCH_ADMIN_KEY}"
LOCATION="${LOCATION:-australiaeast}"
PREFIX="${PREFIX:-learn-ai}"
CONSUMER_GROUP="${CONSUMER_GROUP:-telemetry-decoder-fn}"
SEARCH_API_VERSION="${SEARCH_API_VERSION:-2024-07-01}"
SEARCH_ENDPOINT="https://${SEARCH_SERVICE}.search.windows.net"

echo "=== azure-iot-ai-demo: deploy ==="
echo "Resource Group : $RESOURCE_GROUP"
echo "IoT Hub        : $IOTHUB_NAME"
echo "Storage Account: $STORAGE_ACCOUNT"
echo "Search Service : $SEARCH_SERVICE"
echo ""

# ── 1. Deploy Bicep infrastructure ───────────────────────────────────────────
echo "▶ [1/6] Deploying Bicep infrastructure..."

DEPLOY_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$(dirname "$0")/../infra/main.bicep" \
  --parameters \
      prefix="$PREFIX" \
      location="$LOCATION" \
      iotHubName="$IOTHUB_NAME" \
      storageAccountName="$STORAGE_ACCOUNT" \
      consumerGroupName="$CONSUMER_GROUP" \
  --output json)

FUNCTION_APP_NAME=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.functionAppName.value')
IOTHUB_EH_PATH=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.iotHubEventHubPath.value')
IOTHUB_EH_ENDPOINT=$(echo "$DEPLOY_OUTPUT" | jq -r '.properties.outputs.iotHubEventHubEndpoint.value')

echo "   Function App : $FUNCTION_APP_NAME"
echo "   EH path      : $IOTHUB_EH_PATH"
echo "   EH endpoint  : $IOTHUB_EH_ENDPOINT"

# ── 2. Build IoT Hub Event Hub connection string and update Function App ──────
echo "▶ [2/6] Configuring IoT Hub connection string on Function App..."

# Retrieve iothubowner primary key
IOTHUB_PRIMARY_KEY=$(az iot hub policy show \
  --hub-name "$IOTHUB_NAME" \
  --name "iothubowner" \
  --resource-group "$RESOURCE_GROUP" \
  --query "primaryKey" -o tsv)

# Construct Event Hub-compatible connection string
# Format expected by Azure Functions EventHub trigger:
# Endpoint=sb://<ns>.servicebus.windows.net/;SharedAccessKeyName=iothubowner;SharedAccessKey=<key>;EntityPath=<path>
IOTHUB_EH_CONNSTR="Endpoint=${IOTHUB_EH_ENDPOINT};SharedAccessKeyName=iothubowner;SharedAccessKey=${IOTHUB_PRIMARY_KEY};EntityPath=${IOTHUB_EH_PATH}"

az functionapp config appsettings set \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings "IoTHubConnection=$IOTHUB_EH_CONNSTR" \
  --output none

echo "   IoTHubConnection set on $FUNCTION_APP_NAME"

# ── 3. Deploy Function App code ───────────────────────────────────────────────
echo "▶ [3/6] Installing npm dependencies and publishing Function App..."

(cd "$(dirname "$0")/../function" && npm install --production)

func azure functionapp publish "$FUNCTION_APP_NAME" \
  --javascript \
  --build remote \
  2>&1 | tail -20

echo "   Function deployed."

# ── 4. Configure Azure AI Search ─────────────────────────────────────────────
echo "▶ [4/6] Configuring Azure AI Search datasource, index and indexer..."

# Retrieve storage connection string
STORAGE_CONNSTR=$(az storage account show-connection-string \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query "connectionString" -o tsv)

# Substitute placeholder in datasource template
DS_JSON=$(sed "s|<SEARCH_SERVICE_NAME>|${SEARCH_SERVICE}|g; \
               s|<STORAGE_ACCOUNT_NAME>|${STORAGE_ACCOUNT}|g; \
               s|DefaultEndpointsProtocol=https;AccountName=<STORAGE_ACCOUNT_NAME>;AccountKey=<STORAGE_ACCOUNT_KEY>;EndpointSuffix=core.windows.net|${STORAGE_CONNSTR}|g" \
  "$(dirname "$0")/../search/datasource.json")

INDEX_JSON=$(sed "s|<SEARCH_SERVICE_NAME>|${SEARCH_SERVICE}|g" \
  "$(dirname "$0")/../search/index.json")

INDEXER_JSON=$(sed "s|<SEARCH_SERVICE_NAME>|${SEARCH_SERVICE}|g" \
  "$(dirname "$0")/../search/indexer.json")

SEARCH_HEADERS=(-H "Content-Type: application/json" -H "api-key: ${SEARCH_ADMIN_KEY}")

# Create or update datasource
echo "   Creating/updating datasource..."
curl -sf -X PUT \
  "${SEARCH_ENDPOINT}/datasources/telemetry-decoded-datasource?api-version=${SEARCH_API_VERSION}" \
  "${SEARCH_HEADERS[@]}" \
  -d "$DS_JSON" -o /dev/null

# Create or update index
echo "   Creating/updating index..."
curl -sf -X PUT \
  "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index?api-version=${SEARCH_API_VERSION}" \
  "${SEARCH_HEADERS[@]}" \
  -d "$INDEX_JSON" -o /dev/null

# Create or update indexer
echo "   Creating/updating indexer..."
curl -sf -X PUT \
  "${SEARCH_ENDPOINT}/indexers/telemetry-decoded-indexer?api-version=${SEARCH_API_VERSION}" \
  "${SEARCH_HEADERS[@]}" \
  -d "$INDEXER_JSON" -o /dev/null

# ── 5. Reset and run indexer ──────────────────────────────────────────────────
echo "▶ [5/6] Resetting and running indexer..."

curl -sf -X POST \
  "${SEARCH_ENDPOINT}/indexers/telemetry-decoded-indexer/reset?api-version=${SEARCH_API_VERSION}" \
  "${SEARCH_HEADERS[@]}" -d '{}' -o /dev/null

curl -sf -X POST \
  "${SEARCH_ENDPOINT}/indexers/telemetry-decoded-indexer/run?api-version=${SEARCH_API_VERSION}" \
  "${SEARCH_HEADERS[@]}" -d '{}' -o /dev/null

echo "   Indexer reset and triggered."

# ── 6. Quick smoke test ───────────────────────────────────────────────────────
echo "▶ [6/6] Waiting 30 s then running smoke-test query (temperature gt 20)..."
sleep 30

RESULT=$(curl -sf \
  "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index/docs?\$filter=temperature+gt+20&\$top=3&api-version=${SEARCH_API_VERSION}" \
  -H "api-key: ${SEARCH_ADMIN_KEY}")

COUNT=$(echo "$RESULT" | jq '.value | length')
echo "   Smoke test returned $COUNT document(s) with temperature > 20."
echo "$RESULT" | jq '.value[] | {id, deviceId, temperature, enqueuedTimeUtc}' 2>/dev/null || true

echo ""
echo "✅ Deployment complete!"
echo "   Run  ./scripts/validate.sh  for a full end-to-end validation."
