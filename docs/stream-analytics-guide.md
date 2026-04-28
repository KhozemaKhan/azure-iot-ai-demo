# Stream Analytics IoT Telemetry Ingestion Guide

This guide explains how to route IoT Hub telemetry through **Azure Stream Analytics (ASA)** to produce decoded JSON blobs that Azure AI Search can index — enabling the Foundry agent to detect high-temperature readings and trigger a Logic App alert.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Why Not Direct Event Hub → AI Search?](#why-not-direct-event-hub--ai-search)
3. [Prerequisites](#prerequisites)
4. [Step-by-Step: Portal](#step-by-step-portal)
5. [Step-by-Step: Azure CLI / Bicep](#step-by-step-azure-cli--bicep)
6. [AI Search Configuration](#ai-search-configuration)
7. [Foundry Agent Prompt Guidance](#foundry-agent-prompt-guidance)
8. [Troubleshooting](#troubleshooting)
9. [Sample Queries](#sample-queries)

---

## Architecture Overview

```
IoT Simulator
     │  JSON payload
     ▼
IoT Hub (built-in Event Hub endpoint)
     │  consumer group: telemetry-to-search
     ▼
Azure Stream Analytics job
     │  SQL query: SELECT messageId, deviceId, temperature, humidity,
     │             EventEnqueuedUtcTime AS enqueuedTimeUtc
     ▼
Blob Storage – container: telemetry-decoded
     │  newline-delimited JSON (jsonLines)
     ▼
Azure AI Search Indexer  (parsingMode: jsonLines, runs every 5 min)
     │  fields: messageId, deviceId, temperature, humidity, enqueuedTimeUtc
     ▼
Foundry Agent
     │  $filter=temperature gt 30
     ▼
Logic App (temperature alert)
```

**Key difference from the previous "raw blob" approach:**

| Old approach (broken) | New approach (works) |
|-----------------------|----------------------|
| IoT Hub blob routing writes an *envelope* with `Body` as Base64 | ASA reads from the Event Hub endpoint and receives the original JSON bytes |
| AI Search sees `Body` as an opaque string → `temperature: null` | AI Search sees `temperature` as a top-level numeric field |
| `$filter=temperature gt 30` returns nothing | `$filter=temperature gt 30` returns real results |

---

## Why Not Direct Event Hub → AI Search?

Azure AI Search does **not** have a native Event Hub or IoT Hub data source type. Its built-in indexer data sources are:

- Azure Blob Storage ✅
- Azure SQL ✅
- Cosmos DB ✅
- Azure Table Storage ✅
- Azure Data Lake Storage Gen2 ✅
- **Event Hub / IoT Hub** ❌ (not supported)

Stream Analytics acts as the bridge: it reads from the Event Hub-compatible IoT Hub endpoint in real time and *materialises* the data into Blob Storage (or another supported sink), where AI Search can index it.

---

## Prerequisites

- Azure subscription with Contributor access
- Azure IoT Hub (with the Raspberry Pi simulator sending messages)
- Azure Storage Account
- Azure AI Search service
- Azure CLI ≥ 2.50 (with Bicep support) **or** access to the Azure Portal

---

## Step-by-Step: Portal

### 1. Create a consumer group on IoT Hub

1. Open your IoT Hub → **Built-in endpoints**.
2. Under **Consumer groups**, add: `telemetry-to-search`.
3. Click **Save**.

### 2. Create the `telemetry-decoded` container

1. Open your Storage Account → **Containers**.
2. Click **+ Container**, name it `telemetry-decoded`, set access level to **Private**.
3. Click **Create**.

### 3. Create a Stream Analytics job

1. In the Azure Portal, search for **Stream Analytics jobs** → **+ Create**.
2. Fill in:
   - **Job name**: `iot-telemetry-asa`
   - **Resource group**: your existing RG
   - **Region**: same as IoT Hub
   - **Hosting environment**: Cloud
   - **Streaming units**: 1
3. Click **Create**.

### 4. Add the IoT Hub input

1. Open the ASA job → **Inputs** → **+ Add stream input** → **IoT Hub**.
2. Fill in:
   - **Input alias**: `iothub-input`
   - **Subscription**: your sub
   - **IoT Hub**: your hub
   - **Consumer group**: `telemetry-to-search`
   - **Endpoint**: Messaging
   - **Serialization**: JSON / UTF-8
3. Click **Save**.

### 5. Add the Blob Storage output

1. Open the ASA job → **Outputs** → **+ Add** → **Blob storage / ADLS Gen2**.
2. Fill in:
   - **Output alias**: `telemetry-decoded-output`
   - **Storage account**: your account
   - **Container**: `telemetry-decoded`
   - **Path pattern**: `{date}/{time}`
   - **Date format**: YYYY/MM/DD
   - **Time format**: HH
   - **Serialization**: JSON / UTF-8 / **Line separated**
3. Click **Save**.

> **Important:** Choose **Line separated** (not Array) so each record is a separate JSON line — this matches `parsingMode: jsonLines` in the AI Search indexer.

### 6. Enter the query

1. Open the ASA job → **Query**.
2. Replace the default query with:

```sql
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
```

3. Click **Save query**.

### 7. Start the job

1. On the ASA job overview, click **Start** → **Now** → **Start**.
2. Wait 1-2 minutes for the state to show **Running**.

---

## Step-by-Step: Azure CLI / Bicep

### 1. Deploy infrastructure

```bash
# 1. Clone the repo (if you haven't already)
git clone https://github.com/KhozemaKhan/azure-iot-ai-demo
cd azure-iot-ai-demo

# 2. Deploy (creates consumer group, telemetry-decoded container, ASA job)
./scripts/deploy-asa.sh \
    --resource-group  my-iot-rg \
    --iot-hub         my-iot-hub \
    --storage-account mystorageaccount \
    --location        eastus

# 3. Start the ASA job
./scripts/start-asa.sh \
    --resource-group  my-iot-rg \
    --job-name        iot-telemetry-asa
```

### 2. Configure AI Search

```bash
# Get your storage connection string:
CONN=$(az storage account show-connection-string \
  --resource-group my-iot-rg \
  --name mystorageaccount \
  --query connectionString -o tsv)

# Get your AI Search admin key from Portal → AI Search → Keys

./scripts/setup-search.sh \
    --search-service   learn-ai-aisearch \
    --admin-api-key    <YOUR_ADMIN_API_KEY> \
    --storage-conn-str "$CONN"
```

### 3. Validate

```bash
./scripts/validate-search.sh \
    --search-service learn-ai-aisearch \
    --api-key        <YOUR_QUERY_API_KEY>
```

Expected output when everything is working:
```
=== 3) Documents with temperature > 30 ===
{
    "@odata.count": 12,
    "value": [ ... ]
}
✅ SUCCESS: Found 12 document(s) with temperature > 30.
```

---

## AI Search Configuration

All configs are in the `search/` directory.

### Index schema (`search/index.json`)

| Field | Type | Filterable | Sortable |
|-------|------|------------|----------|
| `id` | `Edm.String` (key) | - | - |
| `messageId` | `Edm.Int32` | ✅ | ✅ |
| `deviceId` | `Edm.String` | ✅ | ✅ |
| `temperature` | `Edm.Double` | ✅ | ✅ |
| `humidity` | `Edm.Double` | ✅ | ✅ |
| `enqueuedTimeUtc` | `Edm.DateTimeOffset` | ✅ | ✅ |

### Datasource (`search/datasource.json`)

Points to `telemetry-decoded` container. Replace `<YOUR_STORAGE_ACCOUNT_CONNECTION_STRING>` with your actual connection string.

### Indexer (`search/indexer.json`)

Key settings:
- `parsingMode: jsonLines` — each line of a blob is a separate document
- `dataToExtract: contentAndMetadata`
- Runs every 5 minutes (configurable via `schedule.interval`)
- Uses `base64Encode` on `metadata_storage_path` for the `id` field

---

## Foundry Agent Prompt Guidance

Update your agent system prompt / instructions to include:

```
You monitor IoT temperature data via Azure AI Search (index: iot-telemetry-index).

When asked about temperature alerts:
1. Query the index with: $filter=temperature gt 30&$orderby=enqueuedTimeUtc desc&$top=10
2. If any results are returned, call the Logic App HTTP trigger with the highest-temperature record as the payload:
   {
     "messageId": <value>,
     "deviceId": <value>,
     "temperature": <value>,
     "humidity": <value>,
     "enqueuedTime": <enqueuedTimeUtc value>
   }
3. If no results, report that no temperatures above 30°C have been recorded recently.

Use the exact field names: temperature (Double), deviceId (String), enqueuedTimeUtc (DateTimeOffset).
```

---

## Troubleshooting

### ASA job won't start

- Check **Activity Log** on the ASA job for ARM errors.
- Ensure the IoT Hub shared access policy `iothubowner` key is correct.
- Make sure the consumer group `telemetry-to-search` exists on the IoT Hub built-in endpoint.

### No blobs appearing in `telemetry-decoded`

1. Confirm the ASA job state is **Running** (not Starting/Degraded).
2. Confirm the IoT simulator is active and sending messages.
3. In the ASA job → **Overview**, check **Input events** counter — it should be > 0.
4. Check **Errors** metrics on the ASA job monitoring tab.

### Blobs exist but AI Search still shows `null` fields

1. Check `parsingMode` in the indexer is **`jsonLines`** (not `json` or `text`).
2. Open one blob in Azure Storage Explorer and verify it contains lines like:
   ```json
   {"messageId":1,"deviceId":"...","temperature":30.8,"humidity":63.4,"enqueuedTimeUtc":"2026-04-28T15:28:48.198Z"}
   ```
3. In AI Search → **Indexers** → your indexer → **Execution history**, check for warnings/errors.
4. **Reset and re-run the indexer** — this forces it to reprocess all blobs:
   ```bash
   # Portal: Indexers → iot-telemetry-indexer → Reset → Run
   # CLI:
   az rest --method post \
     --url "https://learn-ai-aisearch.search.windows.net/indexers/iot-telemetry-indexer/reset?api-version=2023-11-01" \
     --headers "api-key=<ADMIN_KEY>" "Content-Type=application/json"

   az rest --method post \
     --url "https://learn-ai-aisearch.search.windows.net/indexers/iot-telemetry-indexer/run?api-version=2023-11-01" \
     --headers "api-key=<ADMIN_KEY>" "Content-Type=application/json"
   ```

### Agent says "no temperatures above 30" even after fixing the index

1. In AI Search **Search explorer**, run: `$filter=temperature gt 30`
   - If results appear here but not in the agent, the agent is using the wrong query or the wrong index name.
2. Verify the agent is using the field name `temperature` (not `Temperature` — it's case-sensitive).
3. Check that the agent tool is configured with the correct AI Search endpoint and query key.

---

## Sample Queries

Run these in Azure AI Search **Search explorer** or via REST/SDK:

```
# All documents
search=*

# Temperature above 30°C
$filter=temperature gt 30

# Temperature above 30°C, most recent first
$filter=temperature gt 30&$orderby=enqueuedTimeUtc desc

# Specific device
$filter=deviceId eq 'Raspberry Pi Web Client'

# High temperature for specific device, last 10 records
$filter=temperature gt 30 and deviceId eq 'Raspberry Pi Web Client'&$orderby=enqueuedTimeUtc desc&$top=10

# Count of high-temperature readings
$filter=temperature gt 30&$count=true&$top=0
```
