// =============================================================================
// Azure IoT + AI Agent Demo – main infrastructure template
// =============================================================================
// Provisions:
//   • Storage Account with containers telemetry-raw and telemetry-decoded
//   • Azure Function App (consumption, Node 18) with system-assigned managed identity
//   • Application Insights
//   • Azure AI Search (Basic)
//   • Azure IoT Hub (S1) with message routing to telemetry-raw
// =============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short suffix appended to every resource name for uniqueness.')
param suffix string = take(uniqueString(resourceGroup().id), 8)

@description('Storage account name (3-24 chars, lowercase alphanumeric).')
param storageAccountName string = 'stiot${suffix}'

@description('Name for the Function App.')
param functionAppName string = 'func-telemetry-decoder-${suffix}'

@description('Name for the Azure AI Search service.')
param searchServiceName string = 'search-iot-${suffix}'

@description('Name for the IoT Hub.')
param iotHubName string = 'iothub-demo-${suffix}'

// =============================================================================
// Storage Account
// =============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource rawContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'telemetry-raw'
  properties: {
    publicAccess: 'None'
  }
}

resource decodedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'telemetry-decoded'
  properties: {
    publicAccess: 'None'
  }
}

// =============================================================================
// Application Insights
// =============================================================================

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${functionAppName}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 30
  }
}

// =============================================================================
// App Service Plan (Consumption / serverless)
// =============================================================================

resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-${functionAppName}'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {}
}

// =============================================================================
// Function App
// =============================================================================

var storageConnString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      nodeVersion: '~18'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: storageConnString
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: storageConnString
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
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
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~18'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
      ]
    }
  }
  dependsOn: [
    rawContainer
    decodedContainer
  ]
}

// =============================================================================
// Role assignment – Storage Blob Data Contributor for the Function App identity
// (used by the SDK client in telemetryDecoder.js in addition to the conn string)
// =============================================================================

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource funcStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageBlobDataContributorRoleId
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// Azure AI Search
// =============================================================================

resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchServiceName
  location: location
  sku: {
    name: 'basic'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
  }
}

// =============================================================================
// IoT Hub with routing to telemetry-raw
// =============================================================================

resource iotHub 'Microsoft.Devices/IotHubs@2023-06-30' = {
  name: iotHubName
  location: location
  sku: {
    name: 'S1'
    capacity: 1
  }
  properties: {
    routing: {
      endpoints: {
        storageContainers: [
          {
            name: 'telemetry-raw-endpoint'
            connectionString: storageConnString
            containerName: 'telemetry-raw'
            fileNameFormat: '{iothub}/{partition}/{YYYY}/{MM}/{DD}/{HH}/{mm}'
            batchFrequencyInSeconds: 60
            maxChunkSizeInBytes: 10485760
            encoding: 'JSON'
          }
        ]
      }
      routes: [
        {
          name: 'StorageRoute'
          source: 'DeviceMessages'
          condition: 'true'
          endpointNames: [
            'telemetry-raw-endpoint'
          ]
          isEnabled: true
        }
      ]
      fallbackRoute: {
        name: '$fallback'
        source: 'DeviceMessages'
        condition: 'true'
        endpointNames: [
          'events'
        ]
        isEnabled: true
      }
    }
  }
  dependsOn: [
    rawContainer
  ]
}

// =============================================================================
// Outputs
// =============================================================================

output storageAccountName string = storageAccount.name
output storageConnectionString string = storageConnString
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output searchServiceName string = searchService.name
output iotHubName string = iotHub.name
