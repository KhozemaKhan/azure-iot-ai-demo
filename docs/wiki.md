# Azure IoT + AI Agent Temperature Monitoring — Complete Wiki

> **Audience:** Technical architects and engineers who want to replicate, extend, or audit this proof-of-concept solution.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Diagram & Flow](#architecture-diagram--flow)
3. [Solution Walkthrough](#solution-walkthrough)
   - [Step 1 — IoT Hub](#step-1--iot-hub)
   - [Step 2 — IoT Device / Simulator](#step-2--iot-device--simulator)
   - [Step 3 — Stream Analytics Job](#step-3--stream-analytics-job)
   - [Step 4 — Azure Blob Storage (telemetry-decoded)](#step-4--azure-blob-storage-telemetry-decoded)
   - [Step 5 — Azure AI Search Index](#step-5--azure-ai-search-index)
   - [Step 6 — Search Indexer (jsonLines + id mapping)](#step-6--search-indexer-jsonlines--id-mapping)
   - [Step 7 — Azure AI Foundry Agent & Knowledge Base](#step-7--azure-ai-foundry-agent--knowledge-base)
   - [Step 8 — Logic App for Alerting](#step-8--logic-app-for-alerting)
4. [Troubleshooting & FAQ](#troubleshooting--faq)
5. [Best Practices & Lessons Learned](#best-practices--lessons-learned)
6. [References & Links](#references--links)

---

## Overview

This POC demonstrates an **end-to-end IoT telemetry pipeline** that:

1. Streams real-time sensor data (temperature, humidity) from an IoT device into **Azure IoT Hub**.
2. Processes the stream with **Azure Stream Analytics**, enriching each event with a unique `id` and a human-readable `content` field.
3. Persists enriched events as **JSON Lines blobs** in Azure Storage.
4. Indexes every individual event into an **Azure AI Search** index (one document per telemetry reading).
5. Exposes the index as a **Knowledge Base** inside an **Azure AI Foundry** agent.
6. The agent monitors readings in natural language, detects threshold violations (temperature > 30 °C), and fires a **Logic App** alert.

### Key goals demonstrated

| Goal | How achieved |
|---|---|
| Per-event indexing (not per-blob) | Unique `id` field injected by Stream Analytics |
| Retrieval-Augmented Generation (RAG) | Searchable `content` text field per event |
| Numeric filtering | Structured `temperature` / `humidity` fields |
| Zero-touch alerting | Azure AI Foundry agent → Logic App HTTP tool |

---

## Architecture Diagram & Flow

```
┌─────────────────────┐
│   IoT Device /      │
│   Simulator         │
│  (Raspberry Pi /    │
│   Web Client)       │
└────────┬────────────┘
         │  MQTT / AMQP / HTTPS
         ▼
┌─────────────────────┐
│   Azure IoT Hub     │  ← messages land on built-in Event Hub endpoint
│                     │  ← consumer group: asa-consumer-group
└────────┬────────────┘
         │  Event Hub consumer
         ▼
┌─────────────────────┐
│  Azure Stream       │  ← input: iothub (IoT Hub source)
│  Analytics (ASA)    │  ← query: adds `id` + `content` fields
│                     │  ← output: blobOutput (JSON Lines)
└────────┬────────────┘
         │  JSON Lines blobs
         ▼
┌──────────────────────────┐
│  Azure Blob Storage       │
│  container:               │
│  telemetry-decoded        │
└────────┬─────────────────┘
         │  Azure AI Search indexer
         │  (parsingMode: jsonLines)
         ▼
┌─────────────────────┐
│  Azure AI Search    │  ← index: telemetry-index
│  Index              │  ← one document per telemetry event
└────────┬────────────┘
         │  Knowledge Base connection
         ▼
┌─────────────────────┐
│  Azure AI Foundry   │  ← agent with KB + Logic App tool
│  Agent              │
└────────┬────────────┘
         │  HTTP POST
         ▼
┌─────────────────────┐
│  Azure Logic App    │  ← sends email / Teams / SMS alert
│  (Alert trigger)    │
└─────────────────────┘
```

### Data shape at each stage

| Stage | Sample payload |
|---|---|
| IoT Hub (raw) | `{"messageId":1,"deviceId":"device01","temperature":31.56,"humidity":75.87,"enqueuedTimeUtc":"2026-04-29T…"}` |
| After ASA (blob) | Adds `"id":"device01-1"` and `"content":"Telemetry reading. deviceId=device01, …"` |
| Search document | All fields including numeric `temperature`/`humidity` and searchable `content` |

---

## Solution Walkthrough

### Step 1 — IoT Hub

#### 1.1 Create the IoT Hub (Azure Portal / CLI)

```bash
az iot hub create \
  --name learn-ai-iothub \
  --resource-group rg-iot-demo \
  --sku F1 \
  --location eastus
```

> **Free tier (F1)** is sufficient for a demo. Use S1 for production.

#### 1.2 Register a device

```bash
az iot hub device-identity create \
  --hub-name learn-ai-iothub \
  --device-id device01
```

Copy the device connection string for use in the simulator.

#### 1.3 Create a dedicated consumer group for Stream Analytics

> ⚠️ **Trap:** Never let ASA share the `$Default` consumer group with other consumers. Create a dedicated group:

```bash
az iot hub consumer-group create \
  --hub-name learn-ai-iothub \
  --event-hub-name events \
  --name asa-consumer-group
```

Use `asa-consumer-group` when configuring the ASA input.

---

### Step 2 — IoT Device / Simulator

The device (or simulator running in a browser-based Raspberry Pi emulator) sends JSON telemetry over MQTT/HTTPS:

```json
{
  "messageId": 1,
  "deviceId": "device01",
  "temperature": 31.56,
  "humidity": 75.87
}
```

`enqueuedTimeUtc` is added by IoT Hub automatically and surfaced via `EventEnqueuedUtcTime` in Stream Analytics.

---

### Step 3 — Stream Analytics Job

#### 3.1 Create the job

```bash
az stream-analytics job create \
  --name asa-telemetry-job \
  --resource-group rg-iot-demo \
  --location eastus \
  --output-error-policy Drop \
  --events-out-of-order-policy Adjust \
  --events-out-of-order-max-delay-in-seconds 5
```

#### 3.2 Configure the IoT Hub input

In the Portal (Stream Analytics → Inputs → Add → IoT Hub):

| Setting | Value |
|---|---|
| Input alias | `iotHubInput` |
| IoT Hub | `learn-ai-iothub` |
| Consumer group | `asa-consumer-group` ← **use the dedicated group** |
| Shared access policy | `iothubowner` |
| Event serialization | JSON, UTF-8 |

#### 3.3 Configure the Blob Storage output

In the Portal (Stream Analytics → Outputs → Add → Blob Storage):

| Setting | Value |
|---|---|
| Output alias | `blobOutput` |
| Storage account | `learnaistorage` |
| Container | `telemetry-decoded` |
| Path pattern | `{date}/{time}` |
| Date format | YYYY/MM/DD |
| Time format | HH |
| **Event serialization** | **JSON** |
| **Format** | **Line separated (JSON Lines)** ← critical |
| Encoding | UTF-8 |

> ⚠️ **Trap:** The output format **must** be set to `Line separated` (JSON Lines). If you leave it as `Array`, the Search indexer will produce exactly one document per blob regardless of how many events it contains.

#### 3.4 Stream Analytics query

This is the canonical query. Copy it exactly into the ASA Query editor:

```sql
SELECT
    -- Unique key per telemetry event (fixes "1 doc per blob" issue)
    CONCAT(deviceId, '-', CAST(messageId AS nvarchar(max))) AS id,

    -- Structured numeric / string fields for Search filtering
    CAST(messageId AS bigint)        AS messageId,
    CAST(deviceId AS nvarchar(max))  AS deviceId,
    CAST(temperature AS float)       AS temperature,
    CAST(humidity AS float)          AS humidity,
    EventEnqueuedUtcTime             AS enqueuedTimeUtc,

    -- Searchable text field required by Foundry Knowledge Base (RAG)
    CONCAT(
        'Telemetry reading. deviceId=', CAST(deviceId AS nvarchar(max)),
        ', messageId=', CAST(messageId AS nvarchar(max)),
        ', temperatureC=', CAST(temperature AS nvarchar(max)),
        ', humidity=', CAST(humidity AS nvarchar(max)),
        ', enqueuedTimeUtc=', CAST(EventEnqueuedUtcTime AS nvarchar(max))
    ) AS content

INTO   blobOutput
FROM   iotHubInput
```

**Why each field matters:**

| Field | Purpose |
|---|---|
| `id` | Unique key per event — prevents documents overwriting each other in the index |
| `temperature`, `humidity` (numeric) | Enable `$filter=temperature gt 30` queries |
| `content` | Searchable text for Knowledge Base RAG retrieval |

#### 3.5 Start the job

```bash
az stream-analytics job start \
  --name asa-telemetry-job \
  --resource-group rg-iot-demo \
  --output-start-mode JobStartTime
```

#### 3.6 Verify the blob output

Open Azure Storage Explorer or the Portal. In the `telemetry-decoded` container you should see blobs like `2026/04/29/01/0_...json`. Download one and confirm each line is a complete JSON object with `id` and `content`:

```json
{"id":"device01-1","messageId":1,"deviceId":"device01","temperature":31.56,"humidity":75.87,"enqueuedTimeUtc":"2026-04-29T01:20:35.656Z","content":"Telemetry reading. deviceId=device01, messageId=1, temperatureC=31.56129778720926, humidity=75.87297931377583, enqueuedTimeUtc=2026-04-29T01:20:35.6560000Z"}
{"id":"device01-2","messageId":2,"deviceId":"device01","temperature":31.58,"humidity":68.71,"enqueuedTimeUtc":"2026-04-29T01:20:37.562Z","content":"Telemetry reading. deviceId=device01, messageId=2, temperatureC=31.58531345347668, humidity=68.71514737028362, enqueuedTimeUtc=2026-04-29T01:20:37.5620000Z"}
```

If `id` and `content` are missing, the ASA query change has not taken effect — save the query and restart the job.

---

### Step 4 — Azure Blob Storage (telemetry-decoded)

#### 4.1 Create the storage account and container

```bash
az storage account create \
  --name learnaistorage \
  --resource-group rg-iot-demo \
  --sku Standard_LRS \
  --location eastus

az storage container create \
  --name telemetry-decoded \
  --account-name learnaistorage
```

#### 4.2 Grant Search service access (RBAC)

The Search indexer needs read access to the blobs:

```bash
# Get the Search service principal object ID
SEARCH_OID=$(az search service show \
  --name learn-ai-aisearch \
  --resource-group rg-iot-demo \
  --query identity.principalId -o tsv)

az role assignment create \
  --assignee $SEARCH_OID \
  --role "Storage Blob Data Reader" \
  --scope /subscriptions/<sub-id>/resourceGroups/rg-iot-demo/providers/Microsoft.Storage/storageAccounts/learnaistorage
```

---

### Step 5 — Azure AI Search Index

#### 5.1 Create the Search service

```bash
az search service create \
  --name learn-ai-aisearch \
  --resource-group rg-iot-demo \
  --sku free \
  --location eastus
```

> **Free tier** supports one index and one indexer. Use `basic` or higher for production.

#### 5.2 Index schema

Create the index `telemetry-index` via the Portal (Search service → Indexes → Add index) or via the REST API:

```bash
curl -X PUT \
  "https://learn-ai-aisearch.search.windows.net/indexes/telemetry-index?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <your-admin-key>" \
  -d '{
    "name": "telemetry-index",
    "fields": [
      {
        "name": "id",
        "type": "Edm.String",
        "key": true,
        "searchable": false,
        "filterable": true,
        "sortable": true,
        "retrievable": true
      },
      {
        "name": "content",
        "type": "Edm.String",
        "key": false,
        "searchable": true,
        "filterable": false,
        "sortable": false,
        "retrievable": true
      },
      {
        "name": "deviceId",
        "type": "Edm.String",
        "key": false,
        "searchable": true,
        "filterable": true,
        "sortable": false,
        "retrievable": true
      },
      {
        "name": "messageId",
        "type": "Edm.Int64",
        "key": false,
        "searchable": false,
        "filterable": true,
        "sortable": true,
        "retrievable": true
      },
      {
        "name": "temperature",
        "type": "Edm.Double",
        "key": false,
        "searchable": false,
        "filterable": true,
        "sortable": true,
        "retrievable": true
      },
      {
        "name": "humidity",
        "type": "Edm.Double",
        "key": false,
        "searchable": false,
        "filterable": true,
        "sortable": true,
        "retrievable": true
      },
      {
        "name": "enqueuedTimeUtc",
        "type": "Edm.DateTimeOffset",
        "key": false,
        "searchable": false,
        "filterable": true,
        "sortable": true,
        "retrievable": true
      }
    ]
  }'
```

**Minimum required fields and their settings:**

| Field | Type | key | searchable | filterable | sortable | Notes |
|---|---|---|---|---|---|---|
| `id` | Edm.String | ✅ | — | ✅ | ✅ | Comes from JSON, **not** base64-encoded |
| `content` | Edm.String | — | ✅ | — | — | Required for KB RAG retrieval |
| `deviceId` | Edm.String | — | ✅ | ✅ | — | Helps text search and filtering |
| `messageId` | Edm.Int64 | — | — | ✅ | ✅ | Numeric ordering |
| `temperature` | Edm.Double | — | — | ✅ | ✅ | `$filter=temperature gt 30` |
| `humidity` | Edm.Double | — | — | ✅ | ✅ | |
| `enqueuedTimeUtc` | Edm.DateTimeOffset | — | — | ✅ | ✅ | `$orderby=enqueuedTimeUtc desc` |

---

### Step 6 — Search Indexer (jsonLines + id mapping)

#### 6.1 Create a blob datasource

```bash
curl -X POST \
  "https://learn-ai-aisearch.search.windows.net/datasources?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <your-admin-key>" \
  -d '{
    "name": "azureblob-telemetry-datasource",
    "type": "azureblob",
    "credentials": {
      "connectionString": "DefaultEndpointsProtocol=https;AccountName=learnaistorage;AccountKey=<key>;EndpointSuffix=core.windows.net"
    },
    "container": {
      "name": "telemetry-decoded"
    }
  }'
```

#### 6.2 Create the indexer

```bash
curl -X PUT \
  "https://learn-ai-aisearch.search.windows.net/indexers/telemetry-indexer?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <your-admin-key>" \
  -d '{
    "name": "telemetry-indexer",
    "dataSourceName": "azureblob-telemetry-datasource",
    "targetIndexName": "telemetry-index",
    "schedule": {
      "interval": "PT5M",
      "startTime": "2026-04-28T16:44:07.778Z"
    },
    "parameters": {
      "configuration": {
        "dataToExtract": "contentAndMetadata",
        "parsingMode": "jsonLines"
      }
    },
    "fieldMappings": [
      { "sourceFieldName": "id",             "targetFieldName": "id" },
      { "sourceFieldName": "content",        "targetFieldName": "content" },
      { "sourceFieldName": "messageId",      "targetFieldName": "messageId" },
      { "sourceFieldName": "deviceId",       "targetFieldName": "deviceId" },
      { "sourceFieldName": "temperature",    "targetFieldName": "temperature" },
      { "sourceFieldName": "humidity",       "targetFieldName": "humidity" },
      { "sourceFieldName": "enqueuedTimeUtc","targetFieldName": "enqueuedTimeUtc" }
    ],
    "outputFieldMappings": []
  }'
```

> ⚠️ **Critical trap — do NOT use `base64Encode` on `id`:**
>
> If you map `metadata_storage_path → id` with `base64Encode`, every JSON line within the same blob gets the **same key** (the blob path). They overwrite each other, leaving exactly **1 document per blob** instead of 1 document per line. Remove that mapping entirely once your JSON contains its own `id` field.

#### 6.3 Why `parsingMode: jsonLines` matters

| parsingMode | Result |
|---|---|
| `json` (default) | Entire blob = one document |
| `jsonLines` | Each newline-delimited JSON object = one document |

With 3 blobs × 20 lines each, `jsonLines` produces 60 documents; `json` (or `jsonLines` with a non-unique key) produces only 3.

#### 6.4 Reset and run the indexer

After any change to the indexer, datasource, or index schema you **must reset** before running:

```bash
# Reset
curl -X POST \
  "https://learn-ai-aisearch.search.windows.net/indexers/telemetry-indexer/reset?api-version=2023-11-01" \
  -H "api-key: <your-admin-key>"

# Run
curl -X POST \
  "https://learn-ai-aisearch.search.windows.net/indexers/telemetry-indexer/run?api-version=2023-11-01" \
  -H "api-key: <your-admin-key>"
```

#### 6.5 Validate document count

In the Azure Portal (AI Search → Search Explorer) or via REST:

```
GET https://learn-ai-aisearch.search.windows.net/indexes/telemetry-index/docs?search=*&$count=true&$select=id,messageId,deviceId,temperature,enqueuedTimeUtc&api-version=2023-11-01
```

Expected result: `"@odata.count": 60` (or however many lines are in your blobs).

Example of a correctly indexed document:

```json
{
  "@search.score": 1,
  "id": "device01-1",
  "messageId": 1,
  "deviceId": "device01",
  "temperature": 31.56129778720926,
  "humidity": 75.87297931377583,
  "enqueuedTimeUtc": "2026-04-29T01:20:35.656Z",
  "content": "Telemetry reading. deviceId=device01, messageId=1, temperatureC=31.56129778720926, humidity=75.87297931377583, enqueuedTimeUtc=2026-04-29T01:20:35.6560000Z"
}
```

#### 6.6 Validation queries

```
# Find all hot readings
$filter=temperature gt 30&$select=id,deviceId,temperature,enqueuedTimeUtc&$orderby=enqueuedTimeUtc desc&$top=5

# Free-text search for a device
search=device01&$select=id,deviceId,temperature,content

# Search for any Telemetry text (confirms content is indexed)
search=Telemetry reading
```

---

### Step 7 — Azure AI Foundry Agent & Knowledge Base

#### 7.1 Create an Azure AI Foundry project

In the Azure Portal, navigate to **Azure AI Foundry** → Create project:

- Hub name: `learn-ai-hub`
- Project name: `iot-monitoring-project`
- Region: must be the same as or accessible from your Search service

#### 7.2 RBAC — grant Foundry access to Search (critical)

> ⚠️ **This is the single most common reason the KB returns "no data accessible".** Both the **hub managed identity** and the **project managed identity** need the `Search Index Data Reader` role on the Search service.

```bash
# Foundry Hub identity
HUB_OID=$(az ml workspace show \
  --name learn-ai-hub \
  --resource-group rg-iot-demo \
  --query identity.principalId -o tsv)

# Foundry Project identity
PROJECT_OID=$(az ml workspace show \
  --name iot-monitoring-project \
  --resource-group rg-iot-demo \
  --query identity.principalId -o tsv)

SEARCH_SCOPE="/subscriptions/<sub-id>/resourceGroups/rg-iot-demo/providers/Microsoft.Search/searchServices/learn-ai-aisearch"

az role assignment create \
  --assignee $HUB_OID \
  --role "Search Index Data Reader" \
  --scope $SEARCH_SCOPE

az role assignment create \
  --assignee $PROJECT_OID \
  --role "Search Index Data Reader" \
  --scope $SEARCH_SCOPE
```

Also assign `Search Service Contributor` if the KB setup wizard needs to read the index schema:

```bash
az role assignment create \
  --assignee $PROJECT_OID \
  --role "Search Service Contributor" \
  --scope $SEARCH_SCOPE
```

#### 7.3 Add the Knowledge Base

In Foundry → your agent → **Knowledge** → **Add** → **Azure AI Search**:

| Setting | Value |
|---|---|
| Search service | `learn-ai-aisearch` |
| Index | `telemetry-index` |
| Search type | Hybrid (keyword + vector) or Keyword |
| **Content field** | `content` ← **must select this field** |
| Title field | `deviceId` (optional) |
| URL / source field | `id` (optional) |

> **Why `content` must be selected:** The KB retrieval pipeline does a full-text search against the configured content field. If you select a non-searchable field (e.g. `id`), the KB returns nothing. `content` is `searchable: true` and contains human-readable text.

#### 7.4 Agent instructions (updated)

Use these instructions when deploying your agent. They guide the agent to:
- Retrieve telemetry via the Knowledge Base
- Parse structured values from the `content` field
- Trigger the Logic App alert when temperature > 30 °C

```
You are an IoT temperature monitoring agent. Your responsibilities:

1. Use the knowledge base to retrieve recent telemetry readings for all devices.
   - Search for "Telemetry reading" to get the latest records.
   - Each record contains deviceId, messageId, temperatureC, humidity, and enqueuedTimeUtc embedded in the content field.

2. Parse each retrieved record and extract the numeric temperature value from the content field.
   Example content: "Telemetry reading. deviceId=device01, messageId=1, temperatureC=31.56, humidity=75.87, enqueuedTimeUtc=2026-04-29T01:20:35Z"

3. Identify any reading where temperatureC > 30.

4. For every such reading, immediately call the triggertemperaturealert_Tool with the following JSON body,
   replacing the values with the actual values from the retrieved record:
   {
     "messageId": <messageId from record>,
     "deviceId": "<deviceId from record>",
     "temperature": <temperatureC from record>,
     "humidity": <humidity from record>,
     "enqueuedTime": "<enqueuedTimeUtc from record>"
   }

5. After triggering all alerts, respond with a summary:
   - Total readings retrieved
   - Number of readings exceeding 30°C
   - List of alert-triggering readings (deviceId, temperature, timestamp)

6. If the knowledge base returns no results, say so clearly and suggest the user verify
   that the indexer has run and documents exist in the Search index.

Be precise: extract real values from the knowledge base, never use placeholder values.
```

> ⚠️ **Trap:** The old instructions used hard-coded placeholder values (`"messageId": 999, "temperature": 35.5`). The updated instructions above tell the agent to extract **real values** from the KB records before calling the alert tool.

#### 7.5 Validate the agent

In Foundry → Agent → Test:

1. Ask: *"Show me the latest telemetry readings for device01."*
   - Agent should list retrieved `content` strings.
2. Ask: *"Are there any temperature readings above 30°C? Trigger an alert for each one."*
   - Agent should call `triggertemperaturealert_Tool` with real values from the KB.

---

### Step 8 — Logic App for Alerting

#### 8.1 Create the Logic App

```bash
az logic workflow create \
  --name iot-temperature-alert \
  --resource-group rg-iot-demo \
  --location eastus \
  --definition '{
    "$schema": "...",
    "definition": { ... }
  }'
```

In the Portal, use the designer to create:

1. **Trigger:** `When an HTTP request is received` (method: POST)
2. **Action:** Send email (Office 365 / SendGrid) or post Teams message

The HTTP trigger will give you a URL like:
```
https://prod-xx.eastus.logic.azure.com:443/workflows/.../triggers/manual/paths/invoke?...
```

#### 8.2 Expected request body schema

The Logic App expects this JSON (matches what the Foundry agent sends):

```json
{
  "messageId": 1,
  "deviceId": "device01",
  "temperature": 31.56,
  "humidity": 75.87,
  "enqueuedTime": "2026-04-29T01:20:35Z"
}
```

Configure the schema in the HTTP trigger using **Use sample payload to generate schema**.

#### 8.3 Register the Logic App as a tool in Foundry

In Foundry → Agent → **Tools** → **Add** → **HTTP Tool** (or OpenAPI tool):

| Setting | Value |
|---|---|
| Tool name | `triggertemperaturealert_Tool` |
| Method | POST |
| URL | Logic App HTTP trigger URL |
| Body schema | JSON matching the schema above |

---

## Troubleshooting & FAQ

### Q1: Indexer runs but I only see 3 documents (one per blob)

**Root cause:** The `id` field is the same for all JSON lines within a blob.

**Check:** In Search Explorer run:
```
search=*&$select=id,messageId&$top=10
```
If `id` looks like a base64 blob path (e.g. `aHR0cHM6...`), you still have the `metadata_storage_path → id` mapping with `base64Encode`.

**Fix:**
1. Remove the `base64Encode` mapping function from the indexer `id` field mapping.
2. Ensure the ASA query emits an `id` field in each JSON line.
3. Reset and re-run the indexer.

---

### Q2: Knowledge Base says "no data accessible" or agent returns empty results

**Possible causes (check in order):**

| Check | How to verify | Fix |
|---|---|---|
| RBAC missing on Search service | Portal → Search service → Access Control → Role assignments | Add `Search Index Data Reader` to both Foundry hub and project managed identities |
| `content` field not searchable | Portal → Index → Fields → `content` searchable? | Recreate index with `"searchable": true` on `content` |
| KB configured with wrong content field | Foundry → KB config → content field | Re-select `content` as the content field |
| Index is empty | Search Explorer `search=*` returns 0 documents | Reset and re-run indexer; verify blob contains JSON Lines |

---

### Q3: Search filter `$filter=temperature gt 30` returns nothing

**Root cause:** `temperature` field is not numeric or not filterable in the index.

**Check:**
```
GET /indexes/telemetry-index?api-version=2023-11-01
```
Find the `temperature` field. It must be `"type": "Edm.Double"` and `"filterable": true`.

**Fix:** Delete and recreate the index with the correct schema (see Step 5.2). Then reset and re-run the indexer.

---

### Q4: ASA job produces no output / no blobs in container

**Checklist:**
- [ ] IoT Hub input uses the dedicated consumer group `asa-consumer-group` (not `$Default`)
- [ ] Blob output format is **Line separated (JSON Lines)** not `Array`
- [ ] The job is in **Running** state
- [ ] The device/simulator is actively sending messages
- [ ] Check ASA **Diagnostic logs** for errors

---

### Q5: Agent uses placeholder values (999, 35.5) instead of real KB data

**Root cause:** Agent instructions contained a hard-coded JSON template and the agent copy-pasted it without reading the KB.

**Fix:** Use the updated instructions in [Step 7.4](#74-agent-instructions-updated). Specifically:
- Remove hard-coded values
- Instruct the agent to extract values from retrieved KB records
- Tell the agent the exact format of the `content` field

---

### Q6: Indexer warns about unmapped fields / skipped records

If the indexer runs but logs warnings like `"Could not convert field 'temperature' to Edm.Double"`:

- Check that ASA is casting `temperature AS float` (not leaving it as nvarchar).
- Check that the index schema has `"type": "Edm.Double"` for `temperature`.

---

### Q7: RBAC propagation delay

Azure RBAC assignments can take **up to 5 minutes** to propagate. If you just added the `Search Index Data Reader` role and the KB is still failing, wait 5 minutes and try again before investigating other causes.

---

## Best Practices & Lessons Learned

### 1. Always use a dedicated IoT Hub consumer group for ASA

The `$Default` consumer group is shared. If anything else reads from it (e.g., a Function App or the portal's live monitoring), ASA will miss events or throw errors. Create `asa-consumer-group` upfront.

### 2. Inject the unique `id` at the source (Stream Analytics)

Don't rely on the indexer's `metadata_storage_path` as a document key when using `parsingMode: jsonLines`. That path is the same for every line in the same blob, so all lines overwrite each other. Always emit a per-event `id` from ASA (e.g., `CONCAT(deviceId, '-', CAST(messageId AS nvarchar(max)))`).

### 3. Use `base64Encode` only for blob-level keys

`base64Encode` on `metadata_storage_path` is correct when each blob = one document (the default). For `jsonLines`, it actively causes data loss. Remove it once your JSON contains its own `id`.

### 4. Add a human-readable `content` field for RAG

Azure AI Foundry Knowledge Base performs full-text retrieval. Without a `searchable: true` text field, the KB cannot ground responses — it will say "no data found" even when the index has hundreds of documents. The `content` field with a natural language description of each event is the minimal fix.

### 5. Keep numeric fields separate from `content`

Embed human-readable text in `content` for KB retrieval, but also keep `temperature`, `humidity`, and `enqueuedTimeUtc` as typed numeric/date fields. This lets you combine:
- KB/RAG: *"Describe recent hot readings"*
- Structured filter: `$filter=temperature gt 30 &$orderby=enqueuedTimeUtc desc`

### 6. Set ASA output format to JSON Lines (not Array)

The Azure AI Search indexer's `parsingMode: jsonLines` requires **one JSON object per line**, not a JSON array. Verify this in ASA output settings: **Format = Line separated**.

### 7. Grant both Foundry hub and project identities the Search role

Foundry uses two separate managed identities. Both need `Search Index Data Reader`. Missing the project identity is the most common cause of "KB can't access search".

### 8. Always Reset the indexer after schema changes

Changing fieldMappings or the index schema without resetting the indexer leaves stale state. Always: **Reset → Run → Verify doc count**.

### 9. Index schema is immutable — recreate don't patch

Azure AI Search doesn't allow changing a field's type or key flag after creation. If you need to change the schema (e.g., make a field filterable), you must delete and recreate the index.

### 10. Agent instructions must reference real KB field names

Write agent instructions that tell the agent exactly what the `content` text looks like and how to parse values from it. Vague instructions produce hallucinated or placeholder values.

---

## References & Links

| Resource | URL |
|---|---|
| Azure IoT Hub documentation | https://learn.microsoft.com/azure/iot-hub/ |
| Azure Stream Analytics documentation | https://learn.microsoft.com/azure/stream-analytics/ |
| Azure AI Search — Blob indexer | https://learn.microsoft.com/azure/search/search-howto-indexing-azure-blob-storage |
| Azure AI Search — JSON Lines parsing | https://learn.microsoft.com/azure/search/search-howto-index-json-blobs |
| Azure AI Search — Field mappings | https://learn.microsoft.com/azure/search/search-indexer-field-mappings |
| Azure AI Search — RBAC | https://learn.microsoft.com/azure/search/search-security-rbac |
| Azure AI Foundry — Knowledge Base | https://learn.microsoft.com/azure/ai-foundry/how-to/knowledge-base |
| Azure AI Foundry — Agent tools | https://learn.microsoft.com/azure/ai-foundry/how-to/agents |
| Azure Logic Apps — HTTP trigger | https://learn.microsoft.com/azure/logic-apps/logic-apps-http-endpoint |
| ASA query language reference | https://learn.microsoft.com/stream-analytics-query/stream-analytics-query-language-reference |
| `base64Encode` mapping function | https://learn.microsoft.com/azure/search/search-indexer-field-mappings#base64encode-function |
