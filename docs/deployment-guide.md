# Deployment Guide – Azure IoT + AI Agent Temperature Monitoring Demo

## Architecture

```
Raspberry Pi Simulator
       │  (IoT messages)
       ▼
Azure IoT Hub  ──── message routing ────►  Storage: telemetry-raw
                                                   │
                                         Azure Function App
                                      (telemetry-decoder, blob trigger)
                                                   │
                                         Storage: telemetry-decoded
                                                   │
                                         Azure AI Search (indexer)
                                                   │
                                         AI Foundry Agent
                                                   │
                                         Logic App (email alert)
```

### Why the telemetry-decoder Function?

IoT Hub blob routing wraps every device message in an envelope:
```json
{
  "EnqueuedTimeUtc": "2026-04-28T10:30:00.000Z",
  "Properties":      {},
  "SystemProperties": { "connectionDeviceId": "raspberry-pi-simulator" },
  "Body": "eyJtZXNzYWdlSWQiOjEsImRldmljZUlkIjoiUmFzcGJlcnJ5IFBpIFdlYiBDbGllbnQiLCJ0ZW1wZXJhdHVyZSI6MjQuNjIsImh1bWlkaXR5Ijo2MS4yfQ=="
}
```

The `Body` is base64-encoded JSON.  Without the Function, AI Search cannot see
`messageId`, `deviceId`, `temperature`, or `humidity` — they all index as null.

The Function decodes every envelope and writes flat JSON lines to
`telemetry-decoded`:
```json
{"id":"...","messageId":"1","deviceId":"Raspberry Pi Web Client","temperature":24.62,"humidity":61.2,"enqueuedTimeUtc":"2026-04-28T10:30:00.000Z"}
```

---

## Prerequisites

| Tool | Version |
|------|---------|
| [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) | ≥ 2.50 |
| [Azure Functions Core Tools v4](https://github.com/Azure/azure-functions-core-tools) | ≥ 4.0 |
| [Node.js](https://nodejs.org) | 18 LTS |
| `jq` | any recent |

---

## Step-by-Step Deployment

### Step 1 – Log in to Azure

```bash
az login
az account set --subscription "YOUR_SUBSCRIPTION_ID"
```

### Step 2 – Deploy all infrastructure (one command)

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh iot-ai-demo-rg eastus
```

The script:
1. Creates the resource group
2. Deploys the Bicep template (Storage + Function App + AI Search + IoT Hub)
3. Publishes the `telemetry-decoder` Function App
4. Creates the AI Search index, datasource (pointing at `telemetry-decoded`), and
   indexer with `parsingMode: jsonLines`
5. Runs the indexer immediately

At the end it prints the AI Search admin key — save it securely.

### Step 3 – Register an IoT device

```bash
# Replace MY_IOT_HUB with the value printed by setup.sh
az iot hub device-identity create \
  --hub-name MY_IOT_HUB \
  --device-id raspberry-pi-simulator

# Get the connection string (save this!)
az iot hub device-identity connection-string show \
  --hub-name MY_IOT_HUB \
  --device-id raspberry-pi-simulator \
  --output tsv
```

### Step 4 – Start the Raspberry Pi Web Simulator

1. Open <https://azure-samples.github.io/raspberry-pi-web-simulator/#GetStarted>
2. On line 15 replace `[Your IoT hub device connection string]` with the
   connection string from Step 3.
3. The simulator already sends the correct message format:
   ```js
   const message = new Message(JSON.stringify({
     messageId:   messageId,
     deviceId:    'Raspberry Pi Web Client',
     temperature: temperature,
     humidity:    humidity
   }));
   ```
4. Click **Run**.

### Step 5 – Verify the pipeline

#### 5a. Blobs arrive in telemetry-raw

```bash
az storage blob list \
  --container-name telemetry-raw \
  --account-name MY_STORAGE_ACCOUNT \
  --output table
```

Wait 1-2 minutes for IoT Hub to flush its 60-second batch.

#### 5b. Function decodes blobs into telemetry-decoded

```bash
az storage blob list \
  --container-name telemetry-decoded \
  --account-name MY_STORAGE_ACCOUNT \
  --output table
```

You should see the same blob names as in `telemetry-raw`.

#### 5c. AI Search indexes the documents

Check indexer status:
```bash
curl -s \
  "https://MY_SEARCH_SERVICE.search.windows.net/indexers/telemetry-indexer/status?api-version=2023-11-01" \
  -H "api-key: MY_ADMIN_KEY" | jq '.lastResult'
```

Expected: `"status": "success"` and `itemsProcessed > 0`.

#### 5d. Query the index

All documents:
```bash
curl -s \
  "https://MY_SEARCH_SERVICE.search.windows.net/indexes/iot-telemetry-index/docs?api-version=2023-11-01&search=*&\$top=5" \
  -H "api-key: MY_ADMIN_KEY" | jq '.value[] | {deviceId,temperature,humidity,enqueuedTimeUtc}'
```

Filter for high-temperature readings:
```bash
curl -s \
  "https://MY_SEARCH_SERVICE.search.windows.net/indexes/iot-telemetry-index/docs?api-version=2023-11-01&\$filter=temperature gt 30&\$orderby=enqueuedTimeUtc desc" \
  -H "api-key: MY_ADMIN_KEY" | jq '.value[] | {deviceId,temperature,humidity}'
```

---

## Re-running the Indexer Manually

The indexer runs automatically every 5 minutes, but you can trigger it immediately:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "https://MY_SEARCH_SERVICE.search.windows.net/indexers/telemetry-indexer/run?api-version=2023-11-01" \
  -H "api-key: MY_ADMIN_KEY"
# Expected: 202
```

Then poll for completion:
```bash
curl -s \
  "https://MY_SEARCH_SERVICE.search.windows.net/indexers/telemetry-indexer/status?api-version=2023-11-01" \
  -H "api-key: MY_ADMIN_KEY" | jq '.lastResult.status'
```

---

## Sample AI Search Queries

| Purpose | OData filter |
|---------|-------------|
| All documents | `search=*` |
| Temperature > 30 °C | `$filter=temperature gt 30` |
| Specific device | `$filter=deviceId eq 'Raspberry Pi Web Client'` |
| Temperature > 30 + sort newest first | `$filter=temperature gt 30&$orderby=enqueuedTimeUtc desc` |
| Humidity > 70 | `$filter=humidity gt 70` |

Example (for the AI Agent's `trigger_temperature_alert` function):
```
$filter=temperature gt 30&$orderby=enqueuedTimeUtc desc&$top=10
```

---

## AI Foundry Agent Configuration

### System Prompt

```
You are an IoT temperature monitoring agent with access to an Azure AI Search
knowledge base that contains real-time telemetry from IoT devices.

Your responsibilities:
1. Query the search index for recent temperature readings.
2. Identify any device reporting temperature > 30 °C.
3. When such a reading is found, call trigger_temperature_alert with the
   deviceId, temperature, humidity, and enqueuedTimeUtc.
4. Report back what you found and what action was taken.

Use $filter=temperature gt 30&$orderby=enqueuedTimeUtc desc when querying.
```

### Function Definition

```json
{
  "name": "trigger_temperature_alert",
  "description": "Calls the Logic App webhook to send an email alert when temperature exceeds 30 °C.",
  "parameters": {
    "type": "object",
    "properties": {
      "deviceId":       { "type": "string",  "description": "Device ID" },
      "temperature":    { "type": "number",  "description": "Temperature in °C" },
      "humidity":       { "type": "number",  "description": "Relative humidity %" },
      "enqueuedTimeUtc":{ "type": "string",  "description": "ISO 8601 timestamp" }
    },
    "required": ["deviceId", "temperature", "enqueuedTimeUtc"]
  }
}
```

---

## Troubleshooting

### messageId / deviceId / temperature / humidity are null in AI Search

**Root cause**: The indexer was targeting `telemetry-raw` and AI Search cannot
base64-decode the `Body` field automatically.

**Fix**: Ensure the indexer datasource points to `telemetry-decoded` and that
the `telemetry-decoder` Function App is deployed and running.  Then re-run the
indexer.

### telemetry-decoded container is empty

1. Check the Function App logs:
   ```bash
   az webapp log tail --name MY_FUNCTION_APP --resource-group MY_RG
   ```
2. Verify `AzureWebJobsStorage` in the Function App settings points to the
   correct storage account.
3. Make sure at least one blob exists in `telemetry-raw`.

### Indexer shows "no items processed"

- Confirm blobs exist in `telemetry-decoded`.
- Verify the datasource connection string is correct.
- Check `parsingMode` is `jsonLines` in the indexer config.
- Re-run the indexer manually (see above).

### Function not triggering

- Confirm the blob trigger path is `telemetry-raw/{name}`.
- Verify the `AzureWebJobsStorage` connection string matches the storage
  account that IoT Hub writes to.
- Check the Function App extension bundle version supports blob triggers (v4.*).

### Simulator not connecting

- Double-check the device connection string (no extra spaces or newlines).
- Confirm the IoT Hub name matches what was created by the Bicep deployment.
- Ensure the device identity exists:
  ```bash
  az iot hub device-identity show --hub-name MY_IOT_HUB --device-id raspberry-pi-simulator
  ```

---

## Cleanup

```bash
az group delete --name iot-ai-demo-rg --yes --no-wait
```
