# azure-iot-ai-demo
Azure IoT + AI Agent Temperature Monitoring POC

End-to-end demo that connects a **Raspberry Pi Web Simulator** → **Azure IoT Hub** → **Azure AI Search** → **Azure AI Foundry Agent** → **Logic App email alert**.

---

## Architecture Overview

```
Raspberry Pi Web Simulator
        │  (MQTT / HTTPS)
        ▼
  Azure IoT Hub
        │  (Message Routing)
        ▼
  Azure Blob Storage
        │  (Indexer – every 5 min)
        ▼
  Azure AI Search
        │  (Knowledge base tool)
        ▼
  Azure AI Foundry Agent (GPT-4)
        │  (Generic HTTP tool – POST)
        ▼
  Logic App HTTP Trigger
        │  (Condition: temp > 30 °C)
        ▼
  Email Alert 📧
```

---

## Simulator Payload

The Raspberry Pi Web Simulator sends messages in this format:

```json
{
  "messageId": 1,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 24.628269748142735,
  "humidity": 61.215245632443775
}
```

> **Note:** `enqueuedTime` is **not** included in the raw simulator payload. It is added by IoT Hub when routing messages to Blob Storage. Treat it as optional throughout.

---

## Quickstart

### Phase 1 – Azure Infrastructure

#### Step 1: Login and create a resource group

```bash
az login
az account set --subscription "<Your-Subscription-ID>"
az group create --name iot-ai-demo-rg --location eastus
```

#### Step 2: Create IoT Hub and register a device

```bash
az iot hub create \
  --name my-iot-hub-demo \
  --resource-group iot-ai-demo-rg \
  --sku S1 --location eastus

az iot hub device-identity create \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator

# Save the connection string – you need it for the simulator
az iot hub device-identity connection-string show \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator \
  --output tsv
```

#### Step 3: Create Storage and configure message routing

```bash
az storage account create \
  --name iotaidemo12345 \
  --resource-group iot-ai-demo-rg \
  --location eastus --sku Standard_LRS

az storage container create \
  --name telemetry \
  --account-name iotaidemo12345
```

In the Azure Portal, navigate to your IoT Hub → **Message routing** and add:
- **Endpoint:** Storage → container `telemetry`, encoding `JSON`
- **Route:** Data source `Device Telemetry Messages`, query `true`

---

### Phase 2 – IoT Device Simulator

#### Step 4: Start the Raspberry Pi Web Simulator

1. Open [https://azure-samples.github.io/raspberry-pi-web-simulator/](https://azure-samples.github.io/raspberry-pi-web-simulator/).
2. Replace the connection string on line 15 with the value from Step 2.
3. Click **Run**.

The simulator sends the following message every 2 seconds:

```json
{
  "messageId": 1,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 24.63,
  "humidity": 61.22
}
```

---

### Phase 3 – Azure AI Search

#### Step 5: Create the search service and index

```bash
az search service create \
  --name my-ai-search-demo \
  --resource-group iot-ai-demo-rg \
  --sku basic --location eastus

# Retrieve admin key
az search admin-key show \
  --service-name my-ai-search-demo \
  --resource-group iot-ai-demo-rg
```

Create the index (schema matches the simulator payload):

```bash
curl -X POST \
  "https://my-ai-search-demo.search.windows.net/indexes?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <YOUR_ADMIN_KEY>" \
  -d '{
    "name": "iot-telemetry-index",
    "fields": [
      { "name": "id",           "type": "Edm.String",        "key": true,  "searchable": false },
      { "name": "messageId",    "type": "Edm.Int32",          "filterable": true,  "sortable": true },
      { "name": "deviceId",     "type": "Edm.String",         "searchable": true,  "filterable": true },
      { "name": "temperature",  "type": "Edm.Double",         "filterable": true,  "sortable": true },
      { "name": "humidity",     "type": "Edm.Double",         "filterable": true,  "sortable": true },
      { "name": "enqueuedTime", "type": "Edm.DateTimeOffset", "filterable": true,  "sortable": true }
    ]
  }'
```

#### Step 6: Create datasource and indexer

```bash
# Datasource
curl -X POST \
  "https://my-ai-search-demo.search.windows.net/datasources?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <YOUR_ADMIN_KEY>" \
  -d '{
    "name": "telemetry-datasource",
    "type": "azureblob",
    "credentials": { "connectionString": "<STORAGE_CONNECTION_STRING>" },
    "container": { "name": "telemetry" }
  }'

# Indexer (runs every 5 minutes)
curl -X POST \
  "https://my-ai-search-demo.search.windows.net/indexers?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <YOUR_ADMIN_KEY>" \
  -d '{
    "name": "telemetry-indexer",
    "dataSourceName": "telemetry-datasource",
    "targetIndexName": "iot-telemetry-index",
    "schedule": { "interval": "PT5M" },
    "parameters": { "configuration": { "parsingMode": "jsonLines" } }
  }'
```

---

### Phase 4 – Logic App

See the detailed guide in **[logic-app/README.md](logic-app/README.md)**.

Key steps:
1. Create a Consumption Logic App.
2. Add an **HTTP Request** trigger with the [JSON body schema](logic-app/README.md#request-body-json-schema) that matches the simulator payload.
3. Save and **copy the full callback URL** (including the `sig` query parameter).
4. Test it with curl before connecting the Agent.

---

### Phase 5 – Azure AI Foundry Agent

See the detailed guide in **[agent/README.md](agent/README.md)**.

Key steps:
1. Create an AI Foundry project and deploy a GPT-4 model.
2. Connect Azure AI Search as the knowledge base.
3. Add a **generic HTTP tool** (not an OpenAPI wrapper) pointing to the Logic App callback URL.
4. Use `Content-Type: application/json` as a required header.
5. Use the body template that matches the simulator payload fields.

---

### Phase 6 – End-to-End Test

#### Trigger a high-temperature reading

Temporarily modify the simulator to send temperatures above 30 °C:

```javascript
// Original (around line 27):
const temperature = 20 + (Math.random() * 15);

// Changed to force high temperatures:
const temperature = 32 + (Math.random() * 10); // 32–42 °C
```

Wait ~5–10 minutes for:
1. IoT Hub to receive the messages ✅
2. Blob Storage to accumulate data ✅
3. AI Search indexer to run ✅
4. Agent to detect `temperature > 30` ✅
5. Logic App to send the alert email ✅

#### Verify with AI Search query

```bash
curl -X GET \
  "https://my-ai-search-demo.search.windows.net/indexes/iot-telemetry-index/docs?api-version=2023-11-01&\$filter=temperature gt 30&\$orderby=temperature desc&\$top=5" \
  -H "api-key: <YOUR_ADMIN_KEY>"
```

#### Test Logic App directly

```bash
curl -X POST \
  "https://prod-XX.eastus.logic.azure.com:443/workflows/<workflowId>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<signatureValue>" \
  -H "Content-Type: application/json" \
  -d '{
    "messageId": 1,
    "deviceId": "Raspberry Pi Web Client",
    "temperature": 35.5,
    "humidity": 61.2
  }'
```

Expected: `202 Accepted` and an email alert within seconds.

---

## Cleanup

```bash
az group delete --name iot-ai-demo-rg --yes --no-wait
```

---

## Estimated Daily Cost (while actively testing)

| Service | Approximate cost/day |
|---|---|
| IoT Hub S1 | ~$0.83 |
| Azure Blob Storage | ~$0.01 |
| Azure AI Search (Basic) | ~$2.50 |
| Logic App (Consumption) | ~$0.01 |
| AI Foundry / GPT-4 | ~$0.10–$1.00 |
| **Total** | **~$3–5** |

> Delete all resources when not testing to avoid ongoing charges.

---

## Detailed Documentation

| Component | Guide |
|---|---|
| Logic App HTTP Trigger | [logic-app/README.md](logic-app/README.md) |
| AI Foundry Agent + HTTP Tool | [agent/README.md](agent/README.md) |

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| Simulator not connecting | Wrong connection string | Verify the string from `az iot hub device-identity connection-string show` |
| No blobs in Storage | Message routing not configured | Add storage endpoint and route in IoT Hub |
| Indexer not indexing | Wrong `parsingMode` | Set `parsingMode` to `jsonLines` |
| Logic App returns 403 | `sig` missing from URL | Use the full callback URL |
| Logic App returns 400 | Missing `Content-Type` header | Add `Content-Type: application/json` |
| Agent not calling the tool | OpenAPI wrapper used instead | Use generic HTTP tool (see [agent/README.md](agent/README.md)) |
