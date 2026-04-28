# End-to-End Setup Guide

This guide walks you through deploying the complete Azure IoT + AI Agent Temperature Monitoring POC.

---

## Prerequisites

- Active Azure subscription
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) installed and authenticated
- Basic familiarity with the Azure Portal

---

## Phase 1 — Azure Infrastructure

### Step 1 — Login to Azure

```bash
az login

# If you have multiple subscriptions, pin the one you want to use
az account set --subscription "<Your-Subscription-ID>"

# Create a resource group
az group create \
  --name iot-ai-demo-rg \
  --location eastus
```

---

### Step 2 — Create Azure IoT Hub

```bash
az iot hub create \
  --name my-iot-hub-demo \
  --resource-group iot-ai-demo-rg \
  --sku S1 \
  --location eastus
```

---

### Step 3 — Register an IoT Device

```bash
az iot hub device-identity create \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator

# Copy the connection string — you will need it in Phase 2
az iot hub device-identity connection-string show \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator \
  --output tsv
```

Example output:
```
HostName=my-iot-hub-demo.azure-devices.net;DeviceId=raspberry-pi-simulator;SharedAccessKey=xxxxx
```

---

### Step 4 — Create Storage Account

```bash
az storage account create \
  --name iotaidemo12345 \
  --resource-group iot-ai-demo-rg \
  --location eastus \
  --sku Standard_LRS

# Save the connection string
az storage account show-connection-string \
  --name iotaidemo12345 \
  --resource-group iot-ai-demo-rg \
  --output tsv

# Create the blob container
az storage container create \
  --name telemetry \
  --account-name iotaidemo12345
```

---

### Step 5 — Configure IoT Hub Message Routing to Storage

**Via Azure Portal:**

1. Open your IoT Hub → **Message routing** → **Endpoints** tab → **+ Add**.
2. Choose **Storage** as the endpoint type and configure:
   - **Endpoint name:** `storage-endpoint`
   - **Container:** select the `telemetry` container created above
   - **Encoding:** `JSON`
   - **File name format:** `{iothub}/{partition}/{YYYY}/{MM}/{DD}/{HH}/{mm}`
3. Click **Create**.
4. Switch to the **Routes** tab → **+ Add**.
5. Configure the route:
   - **Name:** `StorageRoute`
   - **Endpoint:** `storage-endpoint`
   - **Data source:** Device Telemetry Messages
   - **Routing query:** `true`
6. Click **Save**.

---

## Phase 2 — IoT Device Simulator

### Step 6 — Configure the Raspberry Pi Web Simulator

1. Open the simulator: <https://azure-samples.github.io/raspberry-pi-web-simulator/#GetStarted>
2. On **line 15**, replace the placeholder with your device connection string from Step 3:
   ```javascript
   const connectionString = 'HostName=my-iot-hub-demo.azure-devices.net;DeviceId=raspberry-pi-simulator;SharedAccessKey=xxxxx';
   ```
3. The simulator sends messages in this exact format (do **not** change the payload structure):
   ```json
   {
     "messageId": 1,
     "deviceId": "Raspberry Pi Web Client",
     "temperature": 24.628269748142735,
     "humidity": 61.215245632443775
   }
   ```
4. Click **Run** to start transmitting data.
5. Confirm the console shows `Sending message: {"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":...}`.

> **Note:** Azure IoT Hub appends an `enqueuedTime` property when routing each message to Storage. The JSON blob written to the `telemetry` container therefore contains **five** fields: `messageId`, `deviceId`, `temperature`, `humidity`, and `enqueuedTime`.

---

### Step 7 — Verify Data in Storage

Wait 1–2 minutes, then check:

```bash
az storage blob list \
  --container-name telemetry \
  --account-name iotaidemo12345 \
  --output table
```

Or browse **Storage Account → Containers → telemetry** in the Azure Portal. You should see folders like `my-iot-hub-demo/0/2026/04/28/…`.

Download a blob and confirm the JSON structure:

```json
{
  "messageId": 1,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 24.63,
  "humidity": 61.22,
  "enqueuedTime": "2026-04-28T10:00:00.000Z"
}
```

---

## Phase 3 — Azure AI Search

### Step 8 — Create Azure AI Search Service

```bash
az search service create \
  --name my-ai-search-demo \
  --resource-group iot-ai-demo-rg \
  --sku basic \
  --location eastus

# Save the admin key
az search admin-key show \
  --service-name my-ai-search-demo \
  --resource-group iot-ai-demo-rg
```

---

### Step 9 — Create the Search Index

The index schema reflects the **actual simulator payload** plus the `enqueuedTime` field added by IoT Hub routing.

Save as `index-schema.json`:

```json
{
  "name": "iot-telemetry-index",
  "fields": [
    {
      "name": "id",
      "type": "Edm.String",
      "key": true,
      "searchable": false
    },
    {
      "name": "messageId",
      "type": "Edm.Int32",
      "searchable": false,
      "filterable": true,
      "sortable": true
    },
    {
      "name": "deviceId",
      "type": "Edm.String",
      "searchable": true,
      "filterable": true
    },
    {
      "name": "temperature",
      "type": "Edm.Double",
      "filterable": true,
      "sortable": true
    },
    {
      "name": "humidity",
      "type": "Edm.Double",
      "filterable": true,
      "sortable": true
    },
    {
      "name": "enqueuedTime",
      "type": "Edm.DateTimeOffset",
      "filterable": true,
      "sortable": true
    }
  ]
}
```

Create the index:

```bash
curl -X POST \
  "https://my-ai-search-demo.search.windows.net/indexes?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: YOUR_ADMIN_KEY" \
  -d @index-schema.json
```

---

### Step 10 — Create Data Source

Save as `datasource-config.json`:

```json
{
  "name": "telemetry-datasource",
  "type": "azureblob",
  "credentials": {
    "connectionString": "YOUR_STORAGE_CONNECTION_STRING"
  },
  "container": {
    "name": "telemetry",
    "query": ""
  }
}
```

```bash
curl -X POST \
  "https://my-ai-search-demo.search.windows.net/datasources?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: YOUR_ADMIN_KEY" \
  -d @datasource-config.json
```

---

### Step 11 — Create Indexer

The indexer is configured to parse each blob as a JSON document and map `enqueuedTime` (IoT Hub system property) to the index field.

Save as `indexer-config.json`:

```json
{
  "name": "telemetry-indexer",
  "dataSourceName": "telemetry-datasource",
  "targetIndexName": "iot-telemetry-index",
  "schedule": {
    "interval": "PT5M"
  },
  "parameters": {
    "configuration": {
      "parsingMode": "json"
    }
  },
  "fieldMappings": [
    {
      "sourceFieldName": "messageId",
      "targetFieldName": "messageId"
    },
    {
      "sourceFieldName": "deviceId",
      "targetFieldName": "deviceId"
    },
    {
      "sourceFieldName": "temperature",
      "targetFieldName": "temperature"
    },
    {
      "sourceFieldName": "humidity",
      "targetFieldName": "humidity"
    },
    {
      "sourceFieldName": "enqueuedTime",
      "targetFieldName": "enqueuedTime"
    }
  ]
}
```

```bash
# Create the indexer
curl -X POST \
  "https://my-ai-search-demo.search.windows.net/indexers?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: YOUR_ADMIN_KEY" \
  -d @indexer-config.json

# Run it immediately (don't wait for the 5-minute schedule)
curl -X POST \
  "https://my-ai-search-demo.search.windows.net/indexers/telemetry-indexer/run?api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY"
```

---

### Step 12 — Test the Search Index

```bash
# Return all documents
curl -X GET \
  "https://my-ai-search-demo.search.windows.net/indexes/iot-telemetry-index/docs?api-version=2023-11-01&search=*" \
  -H "api-key: YOUR_ADMIN_KEY"

# Filter for high-temperature readings
curl -X GET \
  "https://my-ai-search-demo.search.windows.net/indexes/iot-telemetry-index/docs?api-version=2023-11-01&\$filter=temperature gt 30&\$orderby=enqueuedTime desc" \
  -H "api-key: YOUR_ADMIN_KEY"
```

---

## Phase 4 — Logic App

### Step 13 — Create Logic App

```bash
az logic workflow create \
  --resource-group iot-ai-demo-rg \
  --location eastus \
  --name temperature-alert-logic-app
```

Or via the Portal: **Create a resource → Logic App → Consumption plan**.

---

### Step 14 — Configure the Logic App Workflow

1. Open the Logic App → **Logic app designer**.
2. **Add trigger:** search for *"When a HTTP request is received"*.
3. Use the following **JSON Schema** for the request body — it matches the simulator payload plus `enqueuedTime`:

   ```json
   {
     "type": "object",
     "properties": {
       "messageId": {
         "type": "integer"
       },
       "deviceId": {
         "type": "string"
       },
       "temperature": {
         "type": "number"
       },
       "humidity": {
         "type": "number"
       },
       "enqueuedTime": {
         "type": "string"
       }
     },
     "required": ["deviceId", "temperature"]
   }
   ```

4. **Add a Condition** step: `temperature` **is greater than** `30`.
5. In the **True** branch, add **Send an email (V2)** (Office 365 Outlook) and configure:
   - **To:** your email address
   - **Subject:** `🌡️ Temperature Alert — @{triggerBody()?['deviceId']}`
   - **Body:**
     ```
     Temperature Alert!

     Device ID    : @{triggerBody()?['deviceId']}
     Message ID   : @{triggerBody()?['messageId']}
     Temperature  : @{triggerBody()?['temperature']} °C
     Humidity     : @{triggerBody()?['humidity']} %
     Enqueued     : @{triggerBody()?['enqueuedTime']}
     ```
6. **Save** the workflow. After saving, copy the **HTTP POST URL** from the trigger — it includes a `sig` query parameter that authenticates requests.

---

### Step 15 — Test Logic App

```bash
curl -X POST \
  "https://prod-xx.eastus.logic.azure.com:443/workflows/<id>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<YOUR_SIG>" \
  -H "Content-Type: application/json" \
  -d '{
    "messageId": 42,
    "deviceId": "Raspberry Pi Web Client",
    "temperature": 35.5,
    "humidity": 60.1,
    "enqueuedTime": "2026-04-28T10:30:00.000Z"
  }'
```

You should receive an alert email.

---

## Phase 5 — Azure AI Foundry Agent

### Step 16 — Create an Azure AI Foundry Project

1. Go to <https://ai.azure.com> → **+ New project**.
2. Configure: **Project name:** `iot-monitoring-project`, **Resource Group:** `iot-ai-demo-rg`.
3. Click **Create**.

---

### Step 17 — Deploy a Model

1. **Deployments → + Create deployment → GPT-4 (or GPT-4-turbo)**.
2. **Deployment name:** `gpt-4-deployment`.

---

### Step 18 — Create the AI Agent

**System prompt:**

```
You are an IoT temperature monitoring agent.

1. Query the Azure AI Search index (iot-telemetry-index) for recent telemetry documents.
2. Each document has: messageId (integer), deviceId (string), temperature (°C, number),
   humidity (% number), and enqueuedTime (ISO-8601 string).
3. When any reading shows temperature > 30 °C, call trigger_temperature_alert immediately.
4. Pass all five fields to the alert function so the email contains full context.
5. Be proactive — always check the most recent readings first (order by enqueuedTime descending).
```

---

### Step 19 — Connect Azure AI Search

1. In the agent configuration → **Data sources → + Add data source → Azure AI Search**.
2. Select `my-ai-search-demo` service and `iot-telemetry-index` index.
3. Provide the admin API key.

---

### Step 20 — Configure the Logic App Action Tool

See [agent-tool-configuration.md](agent-tool-configuration.md) for the full OpenAPI-based setup, including how to embed the Logic App URL with its `sig` parameter.

**Quick summary — function definition:**

```json
{
  "name": "trigger_temperature_alert",
  "description": "Sends a temperature alert by invoking the Logic App webhook. Call this whenever temperature exceeds 30 °C.",
  "parameters": {
    "type": "object",
    "properties": {
      "messageId":     { "type": "integer", "description": "Simulator message sequence number" },
      "deviceId":      { "type": "string",  "description": "Device identifier from the simulator" },
      "temperature":   { "type": "number",  "description": "Temperature in Celsius" },
      "humidity":      { "type": "number",  "description": "Relative humidity in percent" },
      "enqueuedTime":  { "type": "string",  "description": "ISO-8601 timestamp added by IoT Hub" }
    },
    "required": ["deviceId", "temperature", "enqueuedTime"]
  }
}
```

**HTTP action settings:**
- **Type:** HTTP Webhook
- **URL:** full Logic App POST URL (including `sig` query parameter) — see [agent-tool-configuration.md](agent-tool-configuration.md)
- **Method:** POST
- **Headers:** `Content-Type: application/json`
- **Body:** all five fields passed from the function call

---

### Step 21 — Test the Agent

In the agent playground enter:

```
Check the latest temperature readings from the IoT index.
Are there any devices reporting temperature above 30 °C? If so, send an alert.
```

Expected behaviour:
1. Agent queries AI Search.
2. Finds readings > 30 °C.
3. Calls `trigger_temperature_alert` with the five payload fields.
4. You receive an alert email.

---

## Phase 6 — End-to-End Test

### Step 22 — Simulate High Temperature

In the Raspberry Pi Web Simulator, change the temperature range (around line 27):

```javascript
// Original
const temperature = 20 + (Math.random() * 15);   // 20–35 °C

// Change to force alerts
const temperature = 32 + (Math.random() * 10);   // 32–42 °C
```

Click **Run** again. Wait 5–10 minutes for the full pipeline:

| Step | Expected |
|------|----------|
| IoT Hub receives messages | ✅ |
| Blobs appear in Storage | ✅ |
| AI Search indexer runs (every 5 min) | ✅ |
| Agent detects temperature > 30 °C | ✅ |
| Logic App sends email | ✅ |

---

### Step 23 — Verify Each Component

```bash
# 1. Watch live IoT Hub events
az iot hub monitor-events \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator

# 2. Check new blobs
az storage blob list \
  --container-name telemetry \
  --account-name iotaidemo12345 \
  --output table

# 3. Query high-temp readings in AI Search
curl -X GET \
  "https://my-ai-search-demo.search.windows.net/indexes/iot-telemetry-index/docs?api-version=2023-11-01&\$filter=temperature gt 30&\$orderby=enqueuedTime desc" \
  -H "api-key: YOUR_ADMIN_KEY"

# 4. Check Logic App run history in the Portal
#    Logic App → Overview → Runs history
```

---

## Phase 7 — Cleanup

```bash
az group delete \
  --name iot-ai-demo-rg \
  --yes \
  --no-wait
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Simulator shows connection error | Wrong connection string | Re-copy from `az iot hub device-identity connection-string show` |
| No blobs in Storage | Message routing not saved | Re-check Step 5 and save the route |
| Indexer returns 0 documents | Parsing mode mismatch | Ensure `parsingMode: "json"` and blobs contain valid JSON |
| Agent doesn't call alert | Function URL wrong | Verify the full Logic App URL including `sig` — see agent-tool-configuration.md |
| Email not received | Logic App condition | Check `temperature > 30` condition and Runs history |
