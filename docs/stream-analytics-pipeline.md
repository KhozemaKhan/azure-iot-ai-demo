# Stream Analytics Pipeline Guide

## Overview

This document describes how to set up the recommended IoT telemetry pipeline:

```
IoT Simulator → IoT Hub → Stream Analytics → Blob Storage (telemetry-decoded) → AI Search → Foundry Agent → Logic App
```

**Why this pipeline?**
- IoT Hub's native Blob routing wraps the message body in a JSON envelope and Base64-encodes the payload. This means numeric fields like `temperature` land in AI Search as `null`.
- Stream Analytics reads directly from the IoT Hub Event Hub–compatible endpoint, giving you the **original decoded message bytes** (no Base64 envelope), so you can project clean JSON fields.

---

## Prerequisites

- Azure subscription with permission to create resources
- Azure IoT Hub with at least one registered device / simulator running
- Azure Storage Account
- Azure AI Search service (**Standard S1 or higher** — semantic search is not available on Free tier)
- Azure AI Foundry project

---

## Step 1 — Create a Consumer Group on IoT Hub

A dedicated consumer group prevents Stream Analytics from interfering with other readers of the same event stream.

1. Go to **IoT Hub** → **Built-in endpoints**.
2. Under **Consumer groups**, type `asa-to-search` and press **Enter** (or click **Save**).

> Record the values shown on this blade:
> - **Event Hub-compatible endpoint** (used as the Stream Analytics input connection string)
> - **Event Hub-compatible name** (used as the Event Hub name in Stream Analytics)

---

## Step 2 — Create the Output Blob Container

1. Go to your **Storage Account** → **Containers** → **+ Container**.
2. Name: `telemetry-decoded`
3. Public access level: **Private**
4. Click **Create**.

This container will hold clean, newline-delimited JSON files that AI Search can index directly.

---

## Step 3 — Create a Stream Analytics Job

1. In the Azure portal, search for **Stream Analytics jobs** → **+ Create**.
2. Fill in:
   - **Job name**: e.g. `iot-to-search`
   - **Region**: same region as your IoT Hub and Storage Account
   - **Hosting environment**: Cloud
   - **Streaming units**: 1 (sufficient for a POC)
3. Click **Create** and wait for deployment.

---

## Step 4 — Add Input: IoT Hub

1. Open your Stream Analytics job → **Inputs** → **+ Add stream input** → **IoT Hub**.
2. Configure:
   - **Input alias**: `iotHubInput`
   - **Subscription**: your subscription
   - **IoT Hub**: select your IoT Hub
   - **Endpoint**: Messaging (built-in / default)
   - **Consumer group**: `asa-to-search`
   - **Shared access policy name**: `iothubowner` (or a read-only policy)
   - **Serialization format**: JSON
   - **Encoding**: UTF-8
3. Click **Save**.

---

## Step 5 — Add Output: Blob Storage

1. Open your Stream Analytics job → **Outputs** → **+ Add** → **Blob storage / ADLS Gen2**.
2. Configure:
   - **Output alias**: `blobOutput`
   - **Subscription**: your subscription
   - **Storage account**: your storage account
   - **Container**: `telemetry-decoded`
   - **Path pattern**: `telemetry/{date}/{time}` (creates files organized by date/time)
   - **Date format**: `YYYY/MM/DD`
   - **Time format**: `HH`
   - **Event serialization format**: JSON
   - **Format**: **Line separated** (produces newline-delimited JSON — required for `parsingMode: jsonLines` in AI Search)
   - **Encoding**: UTF-8
   - **Minimum rows**: 1 (for POC; increase for production throughput)
   - **Maximum time**: 00:01:00 (flush at least every minute)
3. Click **Save**.

---

## Step 6 — Write the Stream Analytics Query

1. Open your Stream Analytics job → **Query**.
2. Replace the default query with:

```sql
SELECT
    CAST(messageId AS bigint)          AS messageId,
    CAST(deviceId  AS nvarchar(max))   AS deviceId,
    CAST(temperature AS float)         AS temperature,
    CAST(humidity    AS float)         AS humidity,
    EventEnqueuedUtcTime               AS enqueuedTimeUtc
INTO
    [blobOutput]
FROM
    [iotHubInput]
```

3. Click **Save query**.

See [`examples/stream-analytics-query.sql`](../examples/stream-analytics-query.sql) for the full annotated query.

**Why use explicit `CAST`?**
Stream Analytics infers types from the first few events. If early messages contain a field as a string (e.g., `"temperature": "31.9"`), later numeric values may still be treated as strings. Explicit casts eliminate this ambiguity and ensure AI Search receives the correct types.

**Why `EventEnqueuedUtcTime`?**
This is the UTC timestamp when the event reached the IoT Hub Event Hub endpoint. It is more reliable than any timestamp embedded in the device payload.

---

## Step 7 — Start the Stream Analytics Job

1. Open your Stream Analytics job → **Overview** → **Start**.
2. Choose **Now** for the output start time.
3. Click **Start**.

The job takes about 30–60 seconds to reach the **Running** state. Once running:
- Go to **Monitoring** → confirm **Input events** is non-zero after your simulator sends messages.
- Go to your Storage Account → `telemetry-decoded` container → verify files appear.

**Expected file content:**
```json
{"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":30.85,"humidity":63.84,"enqueuedTimeUtc":"2026-04-28T15:28:48.198Z"}
{"messageId":2,"deviceId":"Raspberry Pi Web Client","temperature":31.93,"humidity":75.77,"enqueuedTimeUtc":"2026-04-28T15:28:49.558Z"}
```

Each line is a complete, valid JSON object with **no Base64 encoding** and **no envelope wrapper**.

---

## Step 8 — Create the Azure AI Search Index

Use the REST API, portal, or the example file to create an index with the correct schema.

### Using the portal wizard

1. Azure AI Search → **Indexes** → **+ Add index** → **Import data**.
2. Data source: **Azure Blob Storage**.
3. Container: `telemetry-decoded`.
4. On the **Customize target index** screen, set field types as follows:

| Field | Type | Key | Searchable | Filterable | Sortable | Retrievable |
|---|---|---|---|---|---|---|
| `id` | Edm.String | ✓ | | | | ✓ |
| `content` *(add manually)* | Edm.String | | ✓ | | | ✓ |
| `messageId` | Edm.Int64 | | | ✓ | ✓ | ✓ |
| `deviceId` | Edm.String | | ✓ | ✓ | | ✓ |
| `temperature` | Edm.Double | | | ✓ | ✓ | ✓ |
| `humidity` | Edm.Double | | | ✓ | ✓ | ✓ |
| `enqueuedTimeUtc` | Edm.DateTimeOffset | | | ✓ | ✓ | ✓ |

> **Important:** The `content` field is not produced by Stream Analytics; add it as a computed string in a later step or populate it via a field mapping. See [Azure AI Search Index Requirements](azure-ai-search-index-requirements.md) for details.

### Using the REST API

```bash
curl -X PUT \
  "https://<SEARCH_SERVICE_NAME>.search.windows.net/indexes/telemetry-index?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <ADMIN_API_KEY>" \
  -d @examples/search-index-definition.json
```

---

## Step 9 — Configure the Indexer

### Parsing mode

Set `parsingMode` to **`jsonLines`** because the Stream Analytics output is newline-delimited JSON.

```json
{
  "name": "telemetry-indexer",
  "dataSourceName": "telemetry-decoded-ds",
  "targetIndexName": "telemetry-index",
  "parameters": {
    "configuration": {
      "parsingMode": "jsonLines",
      "dataToExtract": "contentAndMetadata"
    }
  },
  "fieldMappings": [
    {
      "sourceFieldName": "metadata_storage_path",
      "targetFieldName": "id",
      "mappingFunction": { "name": "base64Encode" }
    }
  ],
  "schedule": {
    "interval": "PT5M",
    "startTime": "2000-01-01T00:00:00Z"
  }
}
```

> Setting `interval` to `PT5M` runs the indexer every 5 minutes. For near-real-time updates, use `PT1M` (minimum allowed interval) or trigger the indexer via API when new data arrives.

### Run and verify

1. Azure AI Search → **Indexers** → your indexer → **Run**.
2. Wait for completion; confirm **Items processed** > 0 and **Items failed** = 0.
3. Go to **Search explorer** and run:
   - `search=*` — should return documents
   - `$filter=temperature gt 30` — should return high-temperature records

---

## Step 10 — Add a Semantic Configuration (Required for Foundry Agent)

1. Azure AI Search → your index → **Semantic configurations** → **+ Add**.
2. Name: `telemetry-semantic-config`.
3. Content fields: `content`.
4. Keyword fields: `deviceId`.
5. Save.

This step is mandatory. Without a semantic configuration, Azure AI Foundry will reject the index as *not supported*.

---

## Step 11 — Connect to Azure AI Foundry Agent

1. Open **Azure AI Foundry** → your project → your Agent.
2. Under **Knowledge** → **+ Add data source** → **Azure AI Search**.
3. Select your Search service and `telemetry-index`.
4. Select semantic configuration: `telemetry-semantic-config`.
5. (Optional) Enable **Hybrid search** for better retrieval.
6. Save.

If the index is now accepted, you are ready to test queries against it from the agent.

---

## Step 12 — Validate End-to-End

1. Ensure your IoT simulator is sending telemetry with `temperature > 30`.
2. Stream Analytics job is Running — confirm **Input events** on the monitoring blade.
3. New blobs appear in `telemetry-decoded`.
4. Indexer runs (or wait up to 5 minutes if scheduled) and processes new blobs.
5. In AI Search Explorer: `$filter=temperature gt 30` returns results.
6. In Foundry Agent playground, ask: *"Are there any recent high-temperature readings?"*
7. Agent should retrieve and summarize those records and optionally trigger the Logic App.

---

## Production Considerations

| Area | POC setting | Production recommendation |
|---|---|---|
| Stream Analytics streaming units | 1 | Scale based on input event rate; enable autoscale |
| Indexer schedule | PT5M | PT1M or webhook-triggered for near-real-time |
| Blob path pattern | `telemetry/{date}/{time}` | Include `{datetime}` for finer granularity; consider lifecycle management to archive old blobs |
| AI Search tier | Standard S1 | S2/S3 for high query volume; enable replicas for HA |
| `content` field | Manually constructed string | Use an Azure Function or ASA UDF to generate a descriptive sentence per record |
| Key field | `metadata_storage_path` (base64) | Generate a stable unique ID from `deviceId + messageId` combination |
