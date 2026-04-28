@description('Azure region for all new resources. Defaults to resource group location.')
param location string = resourceGroup().location

@description('Short prefix used to name new resources (e.g. "learn-ai").')
param prefix string = 'learn-ai'

@description('Name of the **existing** IoT Hub.')
param iotHubName string

@description('Name of the **existing** Storage Account that already holds the "telemetry" container.')
param storageAccountName string

@description('Name of the **existing** Azure AI Search service.')
param searchServiceName string = ''

@description('Consumer group name to create on the IoT Hub built-in Event Hub endpoint.')
param consumerGroupName string = 'telemetry-decoder-fn'

// ── Consumer group on IoT Hub built-in endpoint ───────────────────────────────
module consumerGroup 'modules/iothub-consumergroup.bicep' = {
  name: 'consumerGroup'
  params: {
    iotHubName: iotHubName
    consumerGroupName: consumerGroupName
  }
}

// ── telemetry-decoded blob container ─────────────────────────────────────────
module decodedContainer 'modules/storage-container.bicep' = {
  name: 'decodedContainer'
  params: {
    storageAccountName: storageAccountName
    containerName: 'telemetry-decoded'
  }
}

// ── Azure Function App (Event Hub decoder) ───────────────────────────────────
module functionApp 'modules/functionapp.bicep' = {
  name: 'functionApp'
  params: {
    location: location
    prefix: prefix
    storageAccountName: storageAccountName
    iotHubName: iotHubName
    consumerGroupName: consumerGroupName
  }
  dependsOn: [
    consumerGroup
  ]
}

// ── RBAC: Function managed identity → Storage Blob Data Contributor ──────────
module roleAssignments 'modules/roleassignments.bicep' = {
  name: 'roleAssignments'
  params: {
    storageAccountName: storageAccountName
    functionAppPrincipalId: functionApp.outputs.principalId
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output functionAppName string = functionApp.outputs.functionAppName
output iotHubEventHubPath string = functionApp.outputs.iotHubEventHubPath
output iotHubEventHubEndpoint string = functionApp.outputs.iotHubEventHubEndpoint
output decodedContainerName string = decodedContainer.outputs.containerName
