#!/usr/bin/env bash
# =============================================================================
# deploy-function.sh – Build and publish the telemetry-decoder Function App
# =============================================================================
# Usage:
#   chmod +x scripts/deploy-function.sh
#   ./scripts/deploy-function.sh <resource-group> <function-app-name>
#
# Prerequisites:
#   • Azure Functions Core Tools v4  (npm install -g azure-functions-core-tools@4)
#   • Azure CLI (az login)
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${1:-}"
FUNCTION_APP_NAME="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNC_DIR="$(cd "${SCRIPT_DIR}/../functions/telemetry-decoder" && pwd)"

if [[ -z "${RESOURCE_GROUP}" || -z "${FUNCTION_APP_NAME}" ]]; then
  echo "Usage: $0 <resource-group> <function-app-name>"
  exit 1
fi

echo "[INFO] Installing npm dependencies ..."
pushd "${FUNC_DIR}" > /dev/null
npm install --production

echo "[INFO] Publishing '${FUNCTION_APP_NAME}' to resource group '${RESOURCE_GROUP}' ..."
func azure functionapp publish "${FUNCTION_APP_NAME}" --node

popd > /dev/null
echo "[INFO] Function App published successfully."
