#!/usr/bin/env bash
# =============================================================================
# setup.sh – Full infrastructure deployment for the Azure IoT + AI Agent demo
# =============================================================================
# Usage:
#   chmod +x scripts/setup.sh
#   ./scripts/setup.sh [resource-group] [location]
#
# Example:
#   ./scripts/setup.sh iot-ai-demo-rg eastus
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${1:-iot-ai-demo-rg}"
LOCATION="${2:-eastus}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "========================================"
echo " Azure IoT + AI Agent Demo – Setup"
echo "========================================"
echo "Resource group : ${RESOURCE_GROUP}"
echo "Location       : ${LOCATION}"
echo ""

# ── 1. Verify Azure CLI login ────────────────────────────────────────────────
if ! az account show &>/dev/null; then
  echo "[ERROR] Not logged in to Azure CLI. Run: az login"
  exit 1
fi

SUBSCRIPTION=$(az account show --query name -o tsv)
echo "[INFO] Subscription: ${SUBSCRIPTION}"

# ── 2. Create resource group ─────────────────────────────────────────────────
echo "[INFO] Creating resource group '${RESOURCE_GROUP}' in '${LOCATION}' ..."
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none

# ── 3. Deploy Bicep template ─────────────────────────────────────────────────
echo "[INFO] Deploying infrastructure (Bicep) ..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters location="${LOCATION}" \
  --output json)

STORAGE_ACCOUNT=$(echo "${DEPLOYMENT_OUTPUT}" | jq -r '.properties.outputs.storageAccountName.value')
FUNCTION_APP=$(echo "${DEPLOYMENT_OUTPUT}"    | jq -r '.properties.outputs.functionAppName.value')
SEARCH_SERVICE=$(echo "${DEPLOYMENT_OUTPUT}"  | jq -r '.properties.outputs.searchServiceName.value')
IOT_HUB=$(echo "${DEPLOYMENT_OUTPUT}"         | jq -r '.properties.outputs.iotHubName.value')

echo ""
echo "[INFO] Infrastructure deployed:"
echo "  Storage account : ${STORAGE_ACCOUNT}"
echo "  Function App    : ${FUNCTION_APP}"
echo "  AI Search       : ${SEARCH_SERVICE}"
echo "  IoT Hub         : ${IOT_HUB}"

# ── 4. Deploy the Function App ────────────────────────────────────────────────
echo ""
echo "[INFO] Deploying telemetry-decoder function ..."
"${SCRIPT_DIR}/deploy-function.sh" "${RESOURCE_GROUP}" "${FUNCTION_APP}"

# ── 5. Configure AI Search ────────────────────────────────────────────────────
echo ""
echo "[INFO] Retrieving AI Search admin key ..."
SEARCH_ADMIN_KEY=$(az search admin-key show \
  --service-name "${SEARCH_SERVICE}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query primaryKey -o tsv)

SEARCH_ENDPOINT="https://${SEARCH_SERVICE}.search.windows.net"
STORAGE_CONN_STR=$(az storage account show-connection-string \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query connectionString -o tsv)

echo "[INFO] Creating / updating AI Search index ..."
curl -s -o /dev/null -w "  Index HTTP status: %{http_code}\n" -X PUT \
  "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" \
  -d @"${REPO_ROOT}/search/index-schema.json"

echo "[INFO] Creating / updating AI Search datasource ..."
TMP_DS=$(mktemp)
sed "s|__STORAGE_CONNECTION_STRING__|${STORAGE_CONN_STR}|g" \
  "${REPO_ROOT}/search/datasource-config.json" > "${TMP_DS}"
curl -s -o /dev/null -w "  Datasource HTTP status: %{http_code}\n" -X PUT \
  "${SEARCH_ENDPOINT}/datasources/telemetry-datasource?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" \
  -d @"${TMP_DS}"
rm -f "${TMP_DS}"

echo "[INFO] Creating / updating AI Search indexer ..."
curl -s -o /dev/null -w "  Indexer HTTP status: %{http_code}\n" -X PUT \
  "${SEARCH_ENDPOINT}/indexers/telemetry-indexer?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" \
  -d @"${REPO_ROOT}/search/indexer-config.json"

echo "[INFO] Running indexer immediately ..."
curl -s -o /dev/null -w "  Run indexer HTTP status: %{http_code}\n" -X POST \
  "${SEARCH_ENDPOINT}/indexers/telemetry-indexer/run?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}"

echo ""
echo "========================================"
echo " Setup complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Register an IoT device and start the Raspberry Pi simulator"
echo "     (see docs/deployment-guide.md for the exact connection-string steps)"
echo "  2. After a few minutes query AI Search:"
echo ""
echo "     curl -s \"${SEARCH_ENDPOINT}/indexes/iot-telemetry-index/docs"
echo "          ?api-version=2023-11-01&\$filter=temperature gt 30\" \\"
echo "          -H \"api-key: ${SEARCH_ADMIN_KEY}\""
echo ""
echo "  Admin key (save securely): ${SEARCH_ADMIN_KEY}"
