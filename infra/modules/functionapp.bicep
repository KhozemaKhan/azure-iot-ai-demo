@description('Azure region for resources')
param location string

@description('Name prefix for resources')
param prefix string

@description('Name of the existing Storage Account (used for AzureWebJobsStorage)')
param storageAccountName string

@description('Name of the existing IoT Hub (used to build Event Hub connection)')
param iotHubName string

@description('Consumer group name to read from on the IoT Hub built-in endpoint')
param consumerGroupName string

// ── Existing resources ────────────────────────────────────────────────────────
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource iotHub 'Microsoft.Devices/IotHubs@2023-06-30' existing = {
  name: iotHubName
}

// ── App Service Plan (Consumption / Serverless) ───────────────────────────────
resource hostingPlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${prefix}-fn-plan'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true  // required for Linux
  }
  kind: 'functionapp,linux'
}

// ── Function App ──────────────────────────────────────────────────────────────
resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: '${prefix}-decoder-fn'
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    reserved: true
    siteConfig: {
      linuxFxVersion: 'Node|18'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        // IoT Hub built-in Event Hub-compatible endpoint connection string.
        // Format: Endpoint=sb://<ns>.servicebus.windows.net/;SharedAccessKeyName=iothubowner;SharedAccessKey=<key>;EntityPath=<path>
        // Set via deploy.sh after Bicep deployment to avoid storing secrets in parameters.
        {
          name: 'IoTHubConnection'
          value: 'REPLACE_WITH_IOTHUB_EVENTHUB_CONNECTION_STRING'
        }
        {
          name: 'IoTHubEventHubName'
          value: iotHub.properties.eventHubEndpoints.events.path
        }
        {
          name: 'IoTHubConsumerGroup'
          value: consumerGroupName
        }
        {
          name: 'OutputContainerName'
          value: 'telemetry-decoded'
        }
        // Application Insights (optional – remove if not using)
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: 'REPLACE_WITH_APPINSIGHTS_CONNECTION_STRING_OR_REMOVE'
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

output functionAppName string = functionApp.name
output principalId string = functionApp.identity.principalId
output iotHubEventHubPath string = iotHub.properties.eventHubEndpoints.events.path
output iotHubEventHubEndpoint string = iotHub.properties.eventHubEndpoints.events.endpoint
