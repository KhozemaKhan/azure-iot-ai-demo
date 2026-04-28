#!/usr/bin/env bash
# start-asa.sh
# Starts the Azure Stream Analytics job and waits until it reaches Running state.
#
# Usage:
#   ./scripts/start-asa.sh \
#       --resource-group <rg-name> \
#       --job-name       <asa-job-name>   # default: iot-telemetry-asa

set -euo pipefail

JOB_NAME="iot-telemetry-asa"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --job-name)       JOB_NAME="$2";       shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

: "${RESOURCE_GROUP:?'--resource-group is required'}"

echo "=== Starting Stream Analytics job: $JOB_NAME ==="

az stream-analytics job start \
  --resource-group "$RESOURCE_GROUP" \
  --name "$JOB_NAME" \
  --output-start-mode JobStartTime \
  --output none

echo "Start command sent. Polling for Running state (this can take 1-2 minutes)..."

for i in $(seq 1 24); do
  STATE=$(az stream-analytics job show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$JOB_NAME" \
    --query "jobState" \
    --output tsv 2>/dev/null || echo "Unknown")

  echo "  [$(date -u +%H:%M:%S)] Job state: $STATE"

  if [[ "$STATE" == "Running" ]]; then
    echo ""
    echo "=== Job is Running. Telemetry will appear in 'telemetry-decoded' container. ==="
    exit 0
  fi

  sleep 5
done

echo ""
echo "WARNING: Job did not reach Running state within 2 minutes."
echo "Check the Azure Portal → Stream Analytics → $JOB_NAME → Activity Log for errors."
exit 1
