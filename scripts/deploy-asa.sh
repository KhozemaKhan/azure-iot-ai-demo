#!/usr/bin/env bash
# deploy-asa.sh
# Deploys the Stream Analytics infrastructure (Bicep) to your Azure resource group.
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Bicep CLI available (installed automatically with a recent Azure CLI)
#
# Usage:
#   ./scripts/deploy-asa.sh \
#       --resource-group  <rg-name> \
#       --iot-hub         <iot-hub-name> \
#       --storage-account <storage-account-name> \
#       [--location       <azure-region>]           # default: eastus
#       [--job-name       <asa-job-name>]            # default: iot-telemetry-asa
#       [--log-analytics  <workspace-name>]          # default: (empty – no diagnostics)

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
LOCATION="eastus"
JOB_NAME="iot-telemetry-asa"
LOG_ANALYTICS=""
CONSUMER_GROUP="telemetry-to-search"
DECODED_CONTAINER="telemetry-decoded"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)  RESOURCE_GROUP="$2";  shift 2 ;;
    --iot-hub)         IOT_HUB_NAME="$2";    shift 2 ;;
    --storage-account) STORAGE_ACCOUNT="$2"; shift 2 ;;
    --location)        LOCATION="$2";        shift 2 ;;
    --job-name)        JOB_NAME="$2";        shift 2 ;;
    --log-analytics)   LOG_ANALYTICS="$2";   shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Validate required args ────────────────────────────────────────────────────
: "${RESOURCE_GROUP:?'--resource-group is required'}"
: "${IOT_HUB_NAME:?'--iot-hub is required'}"
: "${STORAGE_ACCOUNT:?'--storage-account is required'}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP_FILE="$SCRIPT_DIR/../infra/main.bicep"

echo "=== Deploying Stream Analytics infrastructure ==="
echo "  Resource group : $RESOURCE_GROUP"
echo "  Location       : $LOCATION"
echo "  IoT Hub        : $IOT_HUB_NAME"
echo "  Storage Account: $STORAGE_ACCOUNT"
echo "  ASA Job name   : $JOB_NAME"
echo ""

# ── Ensure resource group exists ─────────────────────────────────────────────
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# ── Deploy Bicep ──────────────────────────────────────────────────────────────
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$BICEP_FILE" \
  --parameters \
      iotHubName="$IOT_HUB_NAME" \
      storageAccountName="$STORAGE_ACCOUNT" \
      streamAnalyticsJobName="$JOB_NAME" \
      location="$LOCATION" \
      asaConsumerGroupName="$CONSUMER_GROUP" \
      decodedContainerName="$DECODED_CONTAINER" \
      logAnalyticsWorkspaceName="$LOG_ANALYTICS" \
  --output table

echo ""
echo "=== Deployment complete ==="
echo "Next step: start the ASA job with ./scripts/start-asa.sh"
