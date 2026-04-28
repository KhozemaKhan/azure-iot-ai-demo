# azure-iot-ai-demo

**Azure IoT + AI Agent Temperature Monitoring POC**

End-to-end pipeline: Raspberry Pi simulator → IoT Hub → Event Hub endpoint → Azure Function → decoded Blob storage → Azure AI Search → AI Agent → Logic App alert.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Root Cause: Why Base64 Breaks Indexing](#root-cause-why-base64-breaks-indexing)
3. [Repository Layout](#repository-layout)
4. [Prerequisites](#prerequisites)
5. [Deployment](#deployment)
   - [Step 1 – Copy and fill parameters file](#step-1--copy-and-fill-parameters-file)
   - [Step 2 – Deploy infrastructure with Bicep](#step-2--deploy-infrastructure-with-bicep)
   - [Step 3 – Set the IoT Hub Event Hub connection string](#step-3--set-the-iot-hub-event-hub-connection-string)
   - [Step 4 – Deploy the Azure Function](#step-4--deploy-the-azure-function)
   - [Step 5 – Configure Azure AI Search](#step-5--configure-azure-ai-search)
   - [Step 6 – Reset and run the indexer](#step-6--reset-and-run-the-indexer)
   - [Step 7 – Configure the AI Agent](#step-7--configure-the-ai-agent)
6. [End-to-End Validation](#end-to-end-validation)
7. [How the Pipeline Works](#how-the-pipeline-works)
8. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Raspberry Pi                                                           Azure AI Foundry
Simulator                                                               Agent
   │                                                                       │
   │  MQTT/HTTPS                                                   query: temp > 30
   ▼                                                                       │
IoT Hub  ──── built-in Event Hub endpoint ────► Azure Function            │
                (IoT Hub consumer group:          (EventHubDecoder)        │
                 telemetry-decoder-fn)                   │                 │
                                                         │ clean JSON      │
                                                         ▼                 │
                                                  Blob Storage             │
                                                  telemetry-decoded  ◄─── AI Search
                                                  (JSON Lines)         (iot-telemetry-index)
                                                                               │
                                                                               │ temperature > 30
                                                                               ▼
                                                                          Logic App
                                                                          (email/Teams alert)
```

### Why this path avoids the Base64 problem

| Routing path | Body encoding | Indexable? |
|---|---|---|
| IoT Hub → **Blob Storage** (message routing) | `Body` is Base64 | ❌ AI Search sees null fields |
| IoT Hub → **Event Hub endpoint** → Function | Body is **raw JSON** | ✅ Function writes clean JSON |

---

## Root Cause: Why Base64 Breaks Indexing

When IoT Hub routes messages directly to Blob Storage it wraps each message in an envelope:

```json
{
  "EnqueuedTimeUtc": "2026-04-28T15:28:49.558Z",
  "Properties": { "temperatureAlert": "true" },
  "SystemProperties": { "connectionDeviceId": "raspberry-pi-simulator", ... },
  "Body": "eyJtZXNzYWdlSWQiOjIsImRldmljZUlkIjoiUmFzcGJlcnJ5IFBpIFdlYiBDbGllbnQiLCJ0ZW1wZXJhdHVyZSI6MzEuOTM..."
}
```

The `Body` field is Base64-encoded. Azure AI Search's blob indexer **cannot** natively decode it and promote the inner fields (`temperature`, `humidity`, etc.) to top-level index fields. Every indexed document therefore has `temperature: null`, and queries like `$filter=temperature gt 30` return zero results.

**Fix:** read from the IoT Hub's built-in Event Hub-compatible endpoint instead. The Event Hub SDK delivers the raw device JSON directly – no envelope, no Base64. The `EventHubDecoder` Azure Function catches each batch, produces clean JSON Lines blobs in `telemetry-decoded`, and AI Search indexes those cleanly.

---

## Repository Layout

```
azure-iot-ai-demo/
├── infra/
│   ├── main.bicep                     # Orchestrates all new Azure resources
│   ├── main.parameters.example.json   # Fill in & rename to main.parameters.json
│   └── modules/
│       ├── iothub-consumergroup.bicep  # Consumer group on IoT Hub built-in EH
│       ├── storage-container.bicep     # telemetry-decoded blob container
│       ├── functionapp.bicep           # Consumption-plan Function App (Node 18)
│       └── roleassignments.bicep       # Storage Blob Data Contributor RBAC
├── function/
│   ├── package.json
│   ├── host.json
│   ├── local.settings.json.template    # Copy to local.settings.json for local dev
│   └── src/
│       ├── functions/
│       │   └── eventhub-decoder.js     # Event Hub trigger → clean JSON blob
│       └── __tests__/
│           └── eventhub-decoder.test.js
├── search/
│   ├── datasource.json                 # Blob datasource → telemetry-decoded
│   ├── index.json                      # Index schema (temperature: Edm.Double etc.)
│   └── indexer.json                    # parsingMode: jsonLines
├── scripts/
│   ├── deploy.sh                       # One-shot deploy + configure script
│   └── validate.sh                     # End-to-end validation
└── README.md
```

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Azure CLI | ≥ 2.55 | `az login` before running scripts |
| Azure Functions Core Tools | v4 | `npm install -g azure-functions-core-tools@4` |
| Node.js | 18 LTS | Function runtime |
| jq | any | Used by shell scripts |
| Existing IoT Hub | any | Already set up and receiving simulator data |
| Existing Storage Account | any | Already holds the `telemetry` container |
| Existing AI Search service | Free or Basic+ | Must support blob indexers |

---

## Deployment

### One-command deploy (recommended)

```bash
export RESOURCE_GROUP=rg-learn-ai
export IOTHUB_NAME=learn-ai-iothub
export STORAGE_ACCOUNT=stlearnai
export SEARCH_SERVICE=learn-ai-aisearch
export SEARCH_ADMIN_KEY=<your-ai-search-admin-key>
# Optional – to also test the Logic App trigger:
# export LOGIC_APP_URL=<full-callback-url-with-sig>

chmod +x scripts/deploy.sh scripts/validate.sh
./scripts/deploy.sh
```

The script performs all six steps automatically. For a manual walkthrough see below.

---

### Step 1 – Copy and fill parameters file

```bash
cp infra/main.parameters.example.json infra/main.parameters.json
# Edit main.parameters.json with your actual resource names
```

### Step 2 – Deploy infrastructure with Bicep

```bash
az deployment group create \
  --resource-group rg-learn-ai \
  --template-file infra/main.bicep \
  --parameters @infra/main.parameters.json
```

This creates:
- **Consumer group** `telemetry-decoder-fn` on the IoT Hub built-in Event Hub endpoint
- **Blob container** `telemetry-decoded` in your storage account
- **Azure Function App** `learn-ai-decoder-fn` (Consumption, Linux, Node 18)
- **Role assignment** – Storage Blob Data Contributor for the Function's managed identity

### Step 3 – Set the IoT Hub Event Hub connection string

The IoT Hub built-in Event Hub endpoint connection string is **not** stored in Bicep parameters (to avoid secrets in source control). Set it manually:

```bash
# Get the IoT Hub's iothubowner primary key
IOTHUB_KEY=$(az iot hub policy show \
  --hub-name learn-ai-iothub \
  --name iothubowner \
  --resource-group rg-learn-ai \
  --query "primaryKey" -o tsv)

# Get the Event Hub-compatible endpoint details
EH_ENDPOINT=$(az iot hub show \
  --name learn-ai-iothub \
  --resource-group rg-learn-ai \
  --query "properties.eventHubEndpoints.events.endpoint" -o tsv)

EH_PATH=$(az iot hub show \
  --name learn-ai-iothub \
  --resource-group rg-learn-ai \
  --query "properties.eventHubEndpoints.events.path" -o tsv)

EH_CONNSTR="Endpoint=${EH_ENDPOINT};SharedAccessKeyName=iothubowner;SharedAccessKey=${IOTHUB_KEY};EntityPath=${EH_PATH}"

# Set on the Function App
az functionapp config appsettings set \
  --name learn-ai-decoder-fn \
  --resource-group rg-learn-ai \
  --settings "IoTHubConnection=${EH_CONNSTR}"
```

### Step 4 – Deploy the Azure Function

```bash
cd function
npm install --production
func azure functionapp publish learn-ai-decoder-fn --javascript
```

### Step 5 – Configure Azure AI Search

Replace placeholders in the JSON files then call the Search REST API:

```bash
SEARCH_ENDPOINT=https://learn-ai-aisearch.search.windows.net
SEARCH_KEY=<your-admin-key>
STORAGE_CONNSTR=$(az storage account show-connection-string \
  --name stlearnai --resource-group rg-learn-ai --query connectionString -o tsv)

# Datasource
curl -X PUT "${SEARCH_ENDPOINT}/datasources/telemetry-decoded-datasource?api-version=2024-07-01" \
  -H "Content-Type: application/json" -H "api-key: ${SEARCH_KEY}" \
  -d "$(sed "s|<STORAGE_ACCOUNT_NAME>|stlearnai|g; \
             s|DefaultEndpointsProtocol=https;AccountName=<STORAGE_ACCOUNT_NAME>;AccountKey=<STORAGE_ACCOUNT_KEY>;EndpointSuffix=core.windows.net|${STORAGE_CONNSTR}|g; \
             s|<SEARCH_SERVICE_NAME>|learn-ai-aisearch|g" search/datasource.json)"

# Index
curl -X PUT "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index?api-version=2024-07-01" \
  -H "Content-Type: application/json" -H "api-key: ${SEARCH_KEY}" \
  -d "$(sed "s|<SEARCH_SERVICE_NAME>|learn-ai-aisearch|g" search/index.json)"

# Indexer
curl -X PUT "${SEARCH_ENDPOINT}/indexers/telemetry-decoded-indexer?api-version=2024-07-01" \
  -H "Content-Type: application/json" -H "api-key: ${SEARCH_KEY}" \
  -d "$(sed "s|<SEARCH_SERVICE_NAME>|learn-ai-aisearch|g" search/indexer.json)"
```

### Step 6 – Reset and run the indexer

Always **reset** the indexer after changing the datasource or container, otherwise previously seen blobs may be skipped:

```bash
SEARCH_ENDPOINT=https://learn-ai-aisearch.search.windows.net
SEARCH_KEY=<your-admin-key>

curl -X POST "${SEARCH_ENDPOINT}/indexers/telemetry-decoded-indexer/reset?api-version=2024-07-01" \
  -H "api-key: ${SEARCH_KEY}" -d '{}'

curl -X POST "${SEARCH_ENDPOINT}/indexers/telemetry-decoded-indexer/run?api-version=2024-07-01" \
  -H "api-key: ${SEARCH_KEY}" -d '{}'
```

Wait ~30 seconds, then verify in Search Explorer:

```
$filter=temperature gt 30&$orderby=enqueuedTimeUtc desc&$top=5
```

You should see documents like:

```json
{
  "id": "Raspberry Pi Web Client-2",
  "messageId": 2,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 31.938,
  "humidity": 75.774,
  "enqueuedTimeUtc": "2026-04-28T15:28:49.558Z"
}
```

### Step 7 – Configure the AI Agent

In Azure AI Foundry, configure your agent with:

**System prompt (add this instruction):**
> When the user asks about temperature alerts or high-temperature readings, use the Azure AI Search tool to query `$filter=temperature gt 30` on the `iot-telemetry-index` index. If any results are found, call the Logic App HTTP tool with the latest record's fields (messageId, deviceId, temperature, humidity, enqueuedTime).

**Generic HTTP tool (for Logic App):**
| Field | Value |
|---|---|
| Method | POST |
| URL | *(full Logic App callback URL including `&sig=...`)* |
| Header | `Content-Type: application/json` |
| Body | `{"messageId": <from search result>, "deviceId": "<from result>", "temperature": <from result>, "humidity": <from result>, "enqueuedTime": "<from result>"}` |

**Logic App trigger schema** – use this in "When a HTTP request is received":
```json
{
  "type": "object",
  "properties": {
    "messageId":   { "type": "integer" },
    "deviceId":    { "type": "string" },
    "temperature": { "type": "number" },
    "humidity":    { "type": "number" },
    "enqueuedTime":{ "type": "string" }
  },
  "required": ["messageId", "deviceId", "temperature", "humidity"]
}
```

---

## End-to-End Validation

Run the validation script to confirm every stage:

```bash
export RESOURCE_GROUP=rg-learn-ai
export STORAGE_ACCOUNT=stlearnai
export SEARCH_SERVICE=learn-ai-aisearch
export SEARCH_ADMIN_KEY=<your-admin-key>
export LOGIC_APP_URL=<full-callback-url>   # optional

./scripts/validate.sh
```

Expected output:
```
✅ PASS: telemetry-decoded container has 12 blob(s)
✅ PASS: Index has 48 total document(s), 48 with non-null temperature
✅ PASS: Found 3 document(s) with temperature > 30
✅ PASS: Logic App responded with HTTP 202
PASS: 4   FAIL: 0
```

---

## How the Pipeline Works

1. **Simulator** (`Raspberry Pi Web Client`) sends JSON over MQTT/HTTPS to IoT Hub:
   ```json
   { "messageId": 1, "deviceId": "Raspberry Pi Web Client", "temperature": 30.86, "humidity": 63.84 }
   ```

2. **IoT Hub built-in Event Hub endpoint** delivers the message to the `telemetry-decoder-fn` consumer group.

3. **EventHubDecoder Azure Function** triggers on each batch:
   - Receives events as parsed JSON objects (no Base64)
   - Produces clean documents: `{ id, messageId, deviceId, temperature, humidity, enqueuedTimeUtc }`
   - Writes all documents as JSON Lines to a new blob in `telemetry-decoded`

4. **Azure AI Search indexer** (`telemetry-decoded-indexer`) polls the container every 5 minutes:
   - `parsingMode: jsonLines` → each line becomes one search document
   - `temperature` and `humidity` are indexed as `Edm.Double` → filterable/sortable

5. **AI Agent** in Azure AI Foundry queries the index:
   ```
   $filter=temperature gt 30&$orderby=enqueuedTimeUtc desc
   ```
   Finds documents → calls Logic App HTTP tool with the telemetry payload.

6. **Logic App** receives the POST and sends an alert (email, Teams, etc.).

---

## Troubleshooting

### Fields still null after reindexing

| Check | Command |
|---|---|
| Are there blobs in `telemetry-decoded`? | `az storage blob list --account-name stlearnai --container-name telemetry-decoded --auth-mode login` |
| Does a blob contain JSON Lines? | `az storage blob download --account-name stlearnai --container-name telemetry-decoded --name <blob-name> --file /tmp/sample.json --auth-mode login && cat /tmp/sample.json` |
| What does the indexer status say? | Azure Portal → AI Search → Indexers → telemetry-decoded-indexer → Execution History |
| Did you reset the indexer? | `curl -X POST .../indexers/telemetry-decoded-indexer/reset?api-version=... -H "api-key: ..."` |

### Function not writing blobs

1. Check Function App logs in Azure Portal → Monitor.
2. Confirm `IoTHubConnection` app setting is correct: it must include `EntityPath=<event-hub-name>`.
3. Confirm the consumer group `telemetry-decoder-fn` exists on the IoT Hub.
4. Make sure the simulator is running and sending messages to IoT Hub.

### Indexer parsingMode

If you see one document per blob file (not per line), the indexer is using the wrong `parsingMode`. Open the indexer JSON in the Portal and confirm:
```json
"configuration": {
  "parsingMode": "jsonLines"
}
```

### Agent says "no high temperature found"

Run the Search Explorer query manually:
```
$filter=temperature gt 30&$top=5
```
- If this returns results → agent instruction/tool config issue. Ensure the agent uses the correct index name and filter syntax.
- If this returns nothing → indexer issue. Follow the steps above to confirm blobs and reindex.

### Logic App not triggering

Test the Logic App directly with curl (bypassing the agent):
```bash
curl -X POST "YOUR_FULL_LOGIC_APP_CALLBACK_URL_WITH_SIG" \
  -H "Content-Type: application/json" \
  -d '{"messageId":999,"deviceId":"test","temperature":35.5,"humidity":60.2,"enqueuedTime":"2026-04-28T10:00:00Z"}'
```
Expected HTTP 202. If this fails, fix the Logic App trigger before debugging the agent.
