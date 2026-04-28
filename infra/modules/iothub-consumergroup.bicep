@description('Name of the existing IoT Hub')
param iotHubName string

@description('Name of the consumer group to create on the built-in Event Hub endpoint')
param consumerGroupName string

resource iotHub 'Microsoft.Devices/IotHubs@2023-06-30' existing = {
  name: iotHubName
}

resource consumerGroup 'Microsoft.Devices/IotHubs/eventHubEndpoints/ConsumerGroups@2023-06-30' = {
  name: '${iotHubName}/events/${consumerGroupName}'
  properties: {
    name: consumerGroupName
  }
}

output consumerGroupName string = consumerGroup.properties.name
