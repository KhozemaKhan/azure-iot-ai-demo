# Azure IoT + AI Agent Temperature Monitoring Demo

End-to-end proof-of-concept that routes IoT device telemetry through Azure IoT
Hub → Blob Storage → Azure Function (Base64 decoder) → Azure AI Search → an
AI Foundry Agent that sends email alerts via Logic App whenever a device reports
temperature above 30 °C.

> **Important:** Azure IoT Hub stores routed messages as Base64-encoded `Body`
> fields inside IoT Hub envelope records.  A pre-processing step (Azure Function)
> is **required** to decode the payloads before they can be indexed by Azure AI
> Search.  Without this step the agent will always report zero high-temperature
> readings.  See [Phase 3](#phase-3-azure-function-decoder-deployment) and
> [docs/troubleshooting.md](docs/troubleshooting.md) for details.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Phase 1 — Azure Infrastructure Setup](#phase-1--azure-infrastructure-setup)
4. [Phase 2 — IoT Device Simulator](#phase-2--iot-device-simulator)
5. [Phase 3 — Azure Function Decoder Deployment](#phase-3--azure-function-decoder-deployment)
6. [Phase 4 — Azure AI Search Setup](#phase-4--azure-ai-search-setup)
7. [Phase 5 — Logic App Alert Setup](#phase-5--logic-app-alert-setup)
8. [Phase 6 — Azure AI Foundry Agent Setup](#phase-6--azure-ai-foundry-agent-setup)
9. [Phase 7 — End-to-End Testing](#phase-7--end-to-end-testing)
10. [Estimated Costs](#estimated-costs)
11. [Cleanup](#cleanup)
12. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Raspberry Pi Web Simulator
        │ {"messageId":1,"deviceId":"Raspberry Pi Web Client",
        │  "temperature":35.7,"humidity":62.1}
        ▼
Azure IoT Hub (S1)
        │ Wraps message in envelope; Base64-encodes the Body
        │ Routes to Blob Storage → container: telemetry/
        ▼
Blob Storage — container: telemetry/
        │ Newline-delimited IoT Hub envelope records (Body = Base64 string)
        │ ⚠ temperature/humidity are NOT visible here — they are inside Body
        ▼
Azure Function: telemetry-decoder        ← KEY DECODING STEP
        │ Blob trigger on telemetry/{name}
        │ Decodes Base64 Body → flat JSON with temperature, humidity, etc.
        │ Writes to container: telemetry-processed/
        ▼
Blob Storage — container: telemetry-processed/
        │ Newline-delimited clean JSON records
        │ {"messageId":1,"deviceId":"...","temperature":35.7,"humidity":62.1,...}
        ▼
Azure AI Search Indexer (parsingMode=jsonLines)
        │ Indexes temperature, humidity, deviceId, messageId, timestamp
        ▼
AI Foundry Agent (GPT-4)
        │ $filter=temperature gt 30
        │ Calls trigger_temperature_alert() when threshold exceeded
        ▼
Logic App → Email alert
```

---

## Prerequisites

- Active Azure subscription
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- [Node.js 18+](https://nodejs.org) installed (for the Azure Function)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local) installed

---

## Phase 1 — Azure Infrastructure Setup

### Step 1 — Login and create a resource group

```bash
az login
az account set --subscription "YOUR_SUBSCRIPTION_ID"

az group create \
  --name iot-ai-demo-rg \
  --location eastus
```

### Step 2 — Create Azure IoT Hub

```bash
az iot hub create \
  --name my-iot-hub-demo \
  --resource-group iot-ai-demo-rg \
  --sku S1 \
  --location eastus
```

### Step 3 — Register an IoT Device

```bash
az iot hub device-identity create \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator

# Save this connection string — you need it for the simulator
az iot hub device-identity connection-string show \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator \
  --output tsv
```

### Step 4 — Create Storage Account and Containers

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

# Raw IoT Hub routing destination
az storage container create \
  --name telemetry \
  --account-name iotaidemo12345

# Decoded output written by the Azure Function
az storage container create \
  --name telemetry-processed \
  --account-name iotaidemo12345
```

### Step 5 — Configure IoT Hub Message Routing

**Via Azure Portal:**

1. Navigate to your IoT Hub → **Message routing**
2. **Endpoints** tab → **+ Add** → **Storage**
   - Endpoint name: `storage-endpoint`
   - Pick the `telemetry` container
   - **Encoding: JSON** ← critical; Avro will break the decoder
   - File name format: `{iothub}/{partition}/{YYYY}/{MM}/{DD}/{HH}/{mm}`
3. **Routes** tab → **+ Add**
   - Name: `StorageRoute`
   - Endpoint: `storage-endpoint`
   - Data source: Device Telemetry Messages
   - Routing query: `true`

> **Why JSON encoding?**  The decoder function expects each line of a blob to
> be valid JSON.  Avro encoding produces binary files that require a different
> parsing approach.

---

## Phase 2 — IoT Device Simulator

### Step 6 — Raspberry Pi Web Simulator

1. Open <https://azure-samples.github.io/raspberry-pi-web-simulator/#GetStarted>
2. Replace the connection string on line 15 with the one from Step 3.
3. The simulator sends the following message format every 2 seconds:

```json
{
  "messageId": 1,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 24.63,
  "humidity": 61.22
}
```

4. Click **Run**.  Confirm you see `Sending message: {...}` in the browser console.

### Step 7 — Simulate High Temperatures (Optional)

To test the alert pipeline, modify the temperature range around line 27:

```javascript
// Default range (20–35 °C):
const temperature = 20 + (Math.random() * 15);

// Change to always be above threshold (32–42 °C):
const temperature = 32 + (Math.random() * 10);
```

---

## Phase 3 — Azure Function Decoder Deployment

This is the most important step.  The function reads every blob from the
`telemetry` container, decodes the Base64 `Body`, and writes clean JSON to
the `telemetry-processed` container.

### Understanding the IoT Hub Blob Format

IoT Hub writes newline-delimited records like this to `telemetry/`:

```json
{"EnqueuedTimeUtc":"2026-04-28T10:30:00.000Z","Properties":{},"SystemProperties":{...},"Body":"BASE64_STRING"}
```

The `Body` when decoded is the actual device payload:

```json
{"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":35.7,"humidity":62.1}
```

The decoder function handles this transformation automatically.

### Step 8 — Deploy the Function App

```bash
# Create a Function App (Node.js 18)
az functionapp create \
  --name my-telemetry-decoder \
  --resource-group iot-ai-demo-rg \
  --storage-account iotaidemo12345 \
  --runtime node \
  --runtime-version 18 \
  --functions-version 4 \
  --consumption-plan-location eastus

# Set the storage connection string so the trigger can read/write blobs
az functionapp config appsettings set \
  --name my-telemetry-decoder \
  --resource-group iot-ai-demo-rg \
  --settings "AzureWebJobsStorage=YOUR_STORAGE_CONNECTION_STRING"

# Deploy the function code
cd functions/telemetry-decoder
func azure functionapp publish my-telemetry-decoder
```

### Step 9 — Verify the Function

1. Portal → Function App → `my-telemetry-decoder` → Functions → `telemetry-decoder` → Monitor
2. You should see one invocation per blob written to `telemetry/`.
3. Check that `telemetry-processed/` now contains corresponding `.json` files.

---

## Phase 4 — Azure AI Search Setup

### Step 10 — Create the Search Service

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

### Step 11 — Create All Search Resources (Automated)

```bash
export SEARCH_SERVICE="my-ai-search-demo"
export SEARCH_ADMIN_KEY="YOUR_ADMIN_KEY"
export STORAGE_CONNECTION_STRING="YOUR_STORAGE_CONNECTION_STRING"
bash scripts/setup-search.sh
```

This script creates:

- **Index** (`iot-telemetry-index`) — fields: `id`, `deviceId`, `messageId`,
  `temperature`, `humidity`, `timestamp`, `enqueuedTimeUtc`
- **Datasource** (`telemetry-processed-datasource`) — points at the
  `telemetry-processed` container (**not** the raw `telemetry` container)
- **Indexer** (`telemetry-indexer`) — `parsingMode=jsonLines`, runs every 5 minutes

> **Why target `telemetry-processed`, not `telemetry`?**
>
> The raw `telemetry` blobs contain IoT Hub envelopes where `temperature` lives
> inside the Base64-encoded `Body` string — not at the document root.  Azure AI
> Search would index `Body` as an opaque string with no numeric fields to filter
> on.  The `telemetry-processed` container holds decoded, flat JSON records that
> the indexer can directly map to the index fields.

### Step 12 — Index Schema Reference

| Field             | Type               | Filterable | Sortable | Notes                       |
|-------------------|--------------------|------------|----------|-----------------------------|
| `id`              | `Edm.String`       | —          | —        | Key field (stable, URL-safe)|
| `deviceId`        | `Edm.String`       | ✓          | ✓        | Exact match                 |
| `messageId`       | `Edm.Int32`        | ✓          | ✓        | Sequential counter          |
| `temperature`     | `Edm.Double`       | ✓          | ✓        | °C — use `gt 30` to filter  |
| `humidity`        | `Edm.Double`       | ✓          | ✓        | Percentage                  |
| `timestamp`       | `Edm.DateTimeOffset` | ✓        | ✓        | Device time (ISO 8601)      |
| `enqueuedTimeUtc` | `Edm.String`       | ✓          | ✓        | IoT Hub ingestion time      |

### Step 13 — Verify Search Results

```bash
# All indexed records (should be > 0)
curl -s \
  "https://my-ai-search-demo.search.windows.net/indexes/iot-telemetry-index/docs?\$count=true&search=*&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool

# Readings above 30 °C
curl -s \
  "https://my-ai-search-demo.search.windows.net/indexes/iot-telemetry-index/docs?\$filter=temperature+gt+30&\$orderby=temperature+desc&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool
```

If the second query returns results with numeric `temperature` values > 30, the
pipeline is working correctly.

---

## Phase 5 — Logic App Alert Setup

### Step 14 — Create Logic App

**Via Azure Portal:**

1. Create resource → Logic App (Consumption plan)
2. Name: `temperature-alert-logic-app`
3. Resource group: `iot-ai-demo-rg`

### Step 15 — Configure Workflow

1. Open Logic App → Logic app designer
2. Add trigger: **When a HTTP request is received**

   Request body JSON schema:
   ```json
   {
     "type": "object",
     "properties": {
       "deviceId":    { "type": "string" },
       "temperature": { "type": "number" },
       "humidity":    { "type": "number" },
       "timestamp":   { "type": "string" }
     }
   }
   ```

3. Add action: **Parse JSON** (use same schema)
4. Add action: **Condition** — `temperature` is greater than `30`
5. In the **True** branch, add: **Send an email (V2)** (Office 365 Outlook)
   - To: your email address
   - Subject: `🚨 Temperature Alert - @{body('Parse_JSON')?['deviceId']}`
   - Body:
     ```
     Temperature Alert!

     Device:      @{body('Parse_JSON')?['deviceId']}
     Temperature: @{body('Parse_JSON')?['temperature']} °C
     Humidity:    @{body('Parse_JSON')?['humidity']} %
     Time:        @{body('Parse_JSON')?['timestamp']}
     ```

6. Save and copy the **HTTP POST URL** from the trigger.

### Step 16 — Test the Logic App

```bash
curl -X POST "YOUR_LOGIC_APP_URL" \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"Raspberry Pi Web Client","temperature":35.5,"humidity":60,"timestamp":"2026-04-28T10:30:00Z"}'
```

---

## Phase 6 — Azure AI Foundry Agent Setup

### Step 17 — Create an AI Foundry Project

1. Go to <https://ai.azure.com> → **New project**
2. Name: `iot-monitoring-project`
3. Resource group: `iot-ai-demo-rg`
4. Deploy **GPT-4** model (deployment name: `gpt-4-deployment`)

### Step 18 — Create the Agent

1. Projects → **Agents** → **+ Create agent**
2. Copy the system prompt from [agent/system-prompt.txt](agent/system-prompt.txt)
3. Set model: `gpt-4-deployment`

### Step 19 — Connect Azure AI Search

In the agent configuration → **Data sources** → **+ Add** → **Azure AI Search**:

- Search service: `my-ai-search-demo`
- Index: `iot-telemetry-index`
- API key: your search admin key

### Step 20 — Add the Alert Function

Add the `trigger_temperature_alert` function with:

- Type: HTTP Webhook
- URL: Logic App webhook URL from Step 15
- Method: POST
- Headers: `Content-Type: application/json`

Function definition (paste into agent):

```json
{
  "name": "trigger_temperature_alert",
  "description": "Calls the Logic App webhook to send an email alert when temperature exceeds threshold",
  "parameters": {
    "type": "object",
    "properties": {
      "deviceId":    { "type": "string", "description": "IoT device identifier" },
      "temperature": { "type": "number", "description": "Temperature in Celsius" },
      "humidity":    { "type": "number", "description": "Humidity percentage" },
      "timestamp":   { "type": "string", "description": "ISO 8601 timestamp" }
    },
    "required": ["deviceId", "temperature", "timestamp"]
  }
}
```

### Step 21 — Test the Agent

In the agent playground:

```
Check the latest temperature readings. Are there any devices above 30 °C?
```

The agent should query the index, identify high readings, call
`trigger_temperature_alert`, and you should receive an email.

---

## Phase 7 — End-to-End Testing

### Step 22 — Simulate High Temperatures

Modify the simulator temperature range as described in Step 7, click **Run**,
and wait 5–10 minutes for the full pipeline.

### Step 23 — Verify Each Stage

```bash
# 1. IoT Hub — live event monitor
az iot hub monitor-events \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator

# 2. Raw blob (should contain Base64 Body)
az storage blob list --container-name telemetry --account-name iotaidemo12345 --output table

# 3. Processed blob (should contain decoded JSON)
az storage blob list --container-name telemetry-processed --account-name iotaidemo12345 --output table

# 4. Search index — readings above 30 °C
curl -s \
  "https://my-ai-search-demo.search.windows.net/indexes/iot-telemetry-index/docs?\$filter=temperature+gt+30&\$orderby=timestamp+desc&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool
```

Check the Logic App **Runs history** in the portal for successful alert runs
and your inbox for alert emails.

---

## Estimated Costs

Running this demo for **1 day**:

| Resource            | ~Cost/day |
|---------------------|-----------|
| IoT Hub (S1)        | $0.83     |
| Storage             | $0.01     |
| AI Search (Basic)   | $2.50     |
| Function App (Consumption) | $0.01 |
| Logic App           | $0.01     |
| AI Foundry (GPT-4)  | $0.10–$1.00 |
| **Total**           | **~$3–5** |

Delete all resources when done to avoid ongoing charges.

---

## Cleanup

```bash
az group delete --name iot-ai-demo-rg --yes --no-wait
```

---

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for:

- Why the agent reports "no temperature > 30" even with high-temp data
- Step-by-step diagnostic checklist
- Sample OData queries to verify indexed values
- Common errors and fixes
- Pipeline reset instructions

### Quick diagnosis

```bash
# Check indexer status
curl -s \
  "https://my-ai-search-demo.search.windows.net/indexers/telemetry-indexer/status?api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool

# Count indexed records
curl -s \
  "https://my-ai-search-demo.search.windows.net/indexes/iot-telemetry-index/docs?\$count=true&search=*&\$top=0&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY"

# Verify temperature field is numeric (not null)
curl -s \
  "https://my-ai-search-demo.search.windows.net/indexes/iot-telemetry-index/docs?search=*&\$select=temperature,deviceId,timestamp&\$top=5&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool
```
