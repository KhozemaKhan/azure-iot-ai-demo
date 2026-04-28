// main.bicepparam – example parameter values; copy and edit for your environment.
using './main.bicep'

// ── Required – replace with your actual resource names ────────────────────────

param iotHubName = 'YOUR_IOT_HUB_NAME'
param storageAccountName = 'YOUR_STORAGE_ACCOUNT_NAME'

// ── Optional – defaults are fine for a POC ────────────────────────────────────

param location = 'eastus'
param streamAnalyticsJobName = 'iot-telemetry-asa'
param asaConsumerGroupName = 'telemetry-to-search'
param decodedContainerName = 'telemetry-decoded'

// Leave empty to skip Log Analytics diagnostics, or set to your workspace name:
param logAnalyticsWorkspaceName = ''
