// modules/stream-analytics.bicep
// Creates the Azure Stream Analytics streaming job that reads from IoT Hub
// (via its Event Hub-compatible built-in endpoint) and writes decoded JSON
// to a Blob Storage container so that Azure AI Search can index the data.

@description('Azure region')
param location string

@description('Name for the Stream Analytics job')
param jobName string

@description('Name of the IoT Hub (used to derive the Event Hub-compatible endpoint keys)')
param iotHubName string

@description('Consumer group name on IoT Hub built-in endpoint')
param iotHubConsumerGroup string

@description('Name of the Storage Account used for the output container')
param storageAccountName string

@description('Name of the output blob container (must already exist)')
param outputContainerName string

@description('Log Analytics workspace name; diagnostics disabled when empty')
param logAnalyticsWorkspaceName string = ''

// ── Retrieve secrets from existing resources ─────────────────────────────────

resource iotHub 'Microsoft.Devices/IotHubs@2023-06-30' existing = {
  name: iotHubName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

// ── Stream Analytics job ─────────────────────────────────────────────────────

resource asaJob 'Microsoft.StreamAnalytics/streamingjobs@2021-10-01-preview' = {
  name: jobName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Standard'
    }
    eventsOutOfOrderPolicy: 'Adjust'
    outputErrorPolicy: 'Stop'
    eventsOutOfOrderMaxDelayInSeconds: 5
    eventsLateArrivalMaxDelayInSeconds: 16
    dataLocale: 'en-US'
    compatibilityLevel: '1.2'

    // ── Input: IoT Hub built-in Event Hub-compatible endpoint ─────────────────
    inputs: [
      {
        name: 'iothub-input'
        properties: {
          type: 'Stream'
          serialization: {
            type: 'Json'
            properties: {
              encoding: 'UTF8'
            }
          }
          datasource: {
            type: 'Microsoft.Devices/IotHubs'
            properties: {
              iotHubNamespace: iotHubName
              sharedAccessPolicyName: 'iothubowner'
              sharedAccessPolicyKey: iotHub.listKeys().value[0].primaryKey
              consumerGroupName: iotHubConsumerGroup
              endpoint: 'messages/events'
            }
          }
        }
      }
    ]

    // ── Output: Blob Storage (newline-delimited JSON) ─────────────────────────
    outputs: [
      {
        name: 'telemetry-decoded-output'
        properties: {
          serialization: {
            type: 'Json'
            properties: {
              encoding: 'UTF8'
              format: 'LineSeparated'
            }
          }
          datasource: {
            type: 'Microsoft.Storage/Blob'
            properties: {
              storageAccounts: [
                {
                  accountName: storageAccountName
                  accountKey: storageAccount.listKeys().value[0].value
                }
              ]
              container: outputContainerName
              pathPattern: '{date}/{time}'
              dateFormat: 'yyyy/MM/dd'
              timeFormat: 'HH'
            }
          }
        }
      }
    ]

    // ── Transformation (SQL query) ────────────────────────────────────────────
    transformation: {
      name: 'MainTransformation'
      properties: {
        streamingUnits: 1
        query: '''
SELECT
    messageId,
    deviceId,
    temperature,
    humidity,
    EventEnqueuedUtcTime AS enqueuedTimeUtc
INTO
    [telemetry-decoded-output]
FROM
    [iothub-input]
'''
      }
    }
  }
}

// ── Diagnostic settings (optional) ───────────────────────────────────────────

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = if (!empty(logAnalyticsWorkspaceName)) {
  name: logAnalyticsWorkspaceName
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceName)) {
  name: '${jobName}-diagnostics'
  scope: asaJob
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'Execution'
        enabled: true
      }
      {
        category: 'Authoring'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output jobName string = asaJob.name
output jobId string = asaJob.id
output principalId string = asaJob.identity.principalId
