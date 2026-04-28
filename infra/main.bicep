// main.bicep
// Deploys Stream Analytics job + supporting resources for IoT telemetry decoding.
// Architecture: IoT Hub (built-in Event Hub endpoint) → Stream Analytics → Blob (telemetry-decoded) → AI Search

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Name of the existing IoT Hub')
param iotHubName string

@description('Name of the existing Storage Account')
param storageAccountName string

@description('Name of the Stream Analytics job to create')
param streamAnalyticsJobName string = 'iot-telemetry-asa'

@description('Name of the Log Analytics workspace for diagnostics (optional; leave empty to skip)')
param logAnalyticsWorkspaceName string = ''

@description('Consumer group to create on IoT Hub built-in endpoint for ASA')
param asaConsumerGroupName string = 'telemetry-to-search'

@description('Output blob container name (will be created if it does not exist)')
param decodedContainerName string = 'telemetry-decoded'

// ────────────────────────────────────────────────────────────────────────────
// References to existing resources
// ────────────────────────────────────────────────────────────────────────────

resource iotHub 'Microsoft.Devices/IotHubs@2023-06-30' existing = {
  name: iotHubName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

// ────────────────────────────────────────────────────────────────────────────
// Consumer group on IoT Hub built-in endpoint (events)
// ────────────────────────────────────────────────────────────────────────────

resource asaConsumerGroup 'Microsoft.Devices/IotHubs/eventHubEndpoints/ConsumerGroups@2023-06-30' = {
  name: '${iotHubName}/events/${asaConsumerGroupName}'
}

// ────────────────────────────────────────────────────────────────────────────
// Blob container: telemetry-decoded
// ────────────────────────────────────────────────────────────────────────────

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource decodedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: decodedContainerName
  properties: {
    publicAccess: 'None'
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Stream Analytics job
// ────────────────────────────────────────────────────────────────────────────

module streamAnalytics 'modules/stream-analytics.bicep' = {
  name: 'stream-analytics-deploy'
  params: {
    location: location
    jobName: streamAnalyticsJobName
    iotHubName: iotHubName
    iotHubConsumerGroup: asaConsumerGroupName
    storageAccountName: storageAccountName
    outputContainerName: decodedContainerName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
  }
  dependsOn: [
    asaConsumerGroup
    decodedContainer
  ]
}

// ────────────────────────────────────────────────────────────────────────────
// Outputs
// ────────────────────────────────────────────────────────────────────────────

output streamAnalyticsJobName string = streamAnalytics.outputs.jobName
output decodedContainerName string = decodedContainer.name
output consumerGroupName string = asaConsumerGroupName
