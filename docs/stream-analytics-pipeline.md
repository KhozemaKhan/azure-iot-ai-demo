# Stream Analytics Pipeline: IoT Telemetry to AI-Powered Alerts

This guide walks you through implementing the end-to-end pipeline:

**IoT Hub → Stream Analytics → Blob (`telemetry-decoded`) → Azure AI Search indexer → Azure AI Foundry agent → Logic App alerts**

---

## Architecture Overview

```
IoT Simulator
     │
     ▼
Azure IoT Hub  ──(built-in Event Hub endpoint)──► Stream Analytics Job
                                                         │
                                              (clean JSON, jsonLines)
                                                         │
                                                         ▼
                                              Blob Storage container
                                               (telemetry-decoded)
                                                         │
                                              (indexer, parsingMode=jsonLines)
                                                         │
                                                         ▼
                                              Azure AI Search index
                                               (iot-telemetry-index)
                                                         │
                                                         ▼
                                              Azure AI Foundry Agent
                                               (queries Search index)
                                                         │
                                                (temperature > 30?)
                                                         │
                                                         ▼
                                              Logic App HTTP trigger
                                               (sends alert / email)
```

### Why this approach avoids the Base64 envelope problem

When you use **IoT Hub → Blob routing** (without Stream Analytics), IoT Hub writes a JSON envelope whose `Body` field contains the original device payload as a **Base64-encoded string**. Azure AI Search cannot automatically decode that `Body` field, so `temperature`, `humidity`, `messageId`, and `deviceId` all appear as `null` in the index.

Stream Analytics reads from the **built-in Event Hub–compatible endpoint** of IoT Hub. At that stage the message body bytes are still the raw device JSON, so Stream Analytics can project the fields directly — no Base64 decoding needed.

---

## Prerequisites

| Resource | Notes |
|---|---|
| Azure IoT Hub | Device and simulator already configured |
| Azure Storage Account | Will host the `telemetry-decoded` container |
| Azure Stream Analytics job | Created in this guide |
| Azure AI Search service | Index `iot-telemetry-index` already exists |
| Azure AI Foundry project | Agent already configured |
| Azure Logic App | HTTP-trigger workflow already configured |

---

## Step 1 — Create a consumer group on IoT Hub

A dedicated consumer group prevents Stream Analytics from conflicting with other readers of the IoT Hub stream.

### Portal

1. Open your **IoT Hub** in the Azure portal.
2. In the left menu select **Built-in endpoints**.
3. Scroll to the **Consumer groups** section.
4. In the text box labelled **Create new consumer group** enter `asa-to-search` and press **Enter** (or click **Save**).

### Azure CLI

```bash
az iot hub consumer-group create \
  --hub-name <IOT_HUB_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --name asa-to-search \
  --eventhub-endpoint events
```

Replace `<IOT_HUB_NAME>` and `<RESOURCE_GROUP>` with your values.

**Verify:**

```bash
az iot hub consumer-group list \
  --hub-name <IOT_HUB_NAME> \
  --eventhub-endpoint events \
  --output table
```

You should see `asa-to-search` in the list.

---

## Step 2 — Create the `telemetry-decoded` storage container

### Portal

1. Open your **Storage Account**.
2. Select **Containers** → **+ Container**.
3. Name: `telemetry-decoded`.
4. Public access level: **Private (no anonymous access)**.
5. Click **Create**.

### Azure CLI

```bash
az storage container create \
  --account-name <STORAGE_ACCOUNT_NAME> \
  --name telemetry-decoded \
  --auth-mode login
```

---

## Step 3 — Create the Stream Analytics job

### Portal

1. In the Azure portal select **Create a resource** → search for **Stream Analytics job** → **Create**.
2. Fill in:
   - **Job name**: e.g. `iot-telemetry-asa`
   - **Subscription / Resource group**: same as IoT Hub
   - **Region**: same region as IoT Hub and Storage (reduces latency and egress cost)
   - **Hosting environment**: Cloud
   - **Streaming units**: `1` (sufficient for POC; increase for production)
3. Click **Review + create** → **Create**.

### Azure CLI

```bash
az stream-analytics job create \
  --resource-group <RESOURCE_GROUP> \
  --name iot-telemetry-asa \
  --location <REGION> \
  --output-error-policy Drop \
  --events-outoforder-policy Adjust \
  --events-outoforder-max-delay-in-seconds 5 \
  --events-late-arrival-max-delay-in-seconds 16 \
  --data-locale en-US
```

---

## Step 4 — Add the IoT Hub input to Stream Analytics

### Portal

1. Open the Stream Analytics job.
2. Under **Job topology** select **Inputs** → **+ Add stream input** → **IoT Hub**.
3. Configure:
   - **Input alias**: `iotHubInput`
   - **Subscription**: select your subscription
   - **IoT Hub**: select your IoT Hub
   - **Consumer group**: `asa-to-search`
   - **Endpoint**: `Messaging`
   - **Shared access policy name**: `iothubowner` (or a custom read policy)
   - **Event serialization format**: `JSON`
   - **Encoding**: `UTF-8`
4. Click **Save**.

### Azure CLI (ARM JSON for input)

Save the following as `/tmp/asa-input.json`:

```json
{
  "properties": {
    "type": "Stream",
    "serialization": {
      "type": "Json",
      "properties": {
        "encoding": "UTF8"
      }
    },
    "datasource": {
      "type": "Microsoft.Devices/IotHubs",
      "properties": {
        "iotHubNamespace": "<IOT_HUB_NAME>",
        "sharedAccessPolicyName": "iothubowner",
        "sharedAccessPolicyKey": "<IOT_HUB_KEY>",
        "consumerGroupName": "asa-to-search",
        "endpoint": "messages/events"
      }
    }
  }
}
```

Then create the input:

```bash
az stream-analytics input create \
  --resource-group <RESOURCE_GROUP> \
  --job-name iot-telemetry-asa \
  --name iotHubInput \
  --properties @/tmp/asa-input.json
```

---

## Step 5 — Add the Blob Storage output to Stream Analytics

### Portal

1. In the Stream Analytics job select **Outputs** → **+ Add** → **Blob storage / ADLS Gen2**.
2. Configure:
   - **Output alias**: `blobOutput`
   - **Subscription / Storage account**: select your storage account
   - **Container**: `telemetry-decoded`
   - **Path pattern**: `{date}/{time}` (or leave blank for a flat container)
   - **Date format**: `YYYY/MM/DD`
   - **Time format**: `HH`
   - **Event serialization format**: `JSON`
   - **Format**: **Line separated**  ← this produces newline-delimited JSON (jsonLines), which is what AI Search needs
   - **Encoding**: `UTF-8`
3. Click **Save**.

> **Important**: The **Line separated** (not *Array*) format is critical. It writes one JSON object per line, which matches the `jsonLines` parsing mode you will configure in the AI Search indexer.

### Azure CLI (ARM JSON for output)

Save the following as `/tmp/asa-output.json`:

```json
{
  "properties": {
    "serialization": {
      "type": "Json",
      "properties": {
        "encoding": "UTF8",
        "format": "LineSeparated"
      }
    },
    "datasource": {
      "type": "Microsoft.Storage/Blob",
      "properties": {
        "storageAccounts": [
          {
            "accountName": "<STORAGE_ACCOUNT_NAME>",
            "accountKey": "<STORAGE_ACCOUNT_KEY>"
          }
        ],
        "container": "telemetry-decoded",
        "pathPattern": "{date}/{time}",
        "dateFormat": "YYYY/MM/DD",
        "timeFormat": "HH"
      }
    }
  }
}
```

```bash
az stream-analytics output create \
  --resource-group <RESOURCE_GROUP> \
  --job-name iot-telemetry-asa \
  --name blobOutput \
  --properties @/tmp/asa-output.json
```

---

## Step 6 — Write the Stream Analytics query

### Portal

1. In the Stream Analytics job select **Query** under **Job topology**.
2. Replace the default query with:

```sql
SELECT
    CAST(messageId    AS bigint)        AS messageId,
    CAST(deviceId     AS nvarchar(max)) AS deviceId,
    CAST(temperature  AS float)         AS temperature,
    CAST(humidity     AS float)         AS humidity,
    EventEnqueuedUtcTime                AS enqueuedTimeUtc
INTO
    [blobOutput]
FROM
    [iotHubInput]
```

3. Click **Save query**.

### Notes on the query

| Clause | Reason |
|---|---|
| `CAST(messageId AS bigint)` | Ensures the field is stored as a number, not a string |
| `CAST(temperature AS float)` | Ensures filterable numeric type in AI Search |
| `EventEnqueuedUtcTime AS enqueuedTimeUtc` | Built-in ASA metadata timestamp; becomes `Edm.DateTimeOffset` in the index |
| `INTO [blobOutput]` | Must match the output alias exactly |
| `FROM [iotHubInput]` | Must match the input alias exactly |

### Azure CLI (save and apply query)

Save the query to `/tmp/asa-query.sql`, then:

```bash
az stream-analytics transformation create \
  --resource-group <RESOURCE_GROUP> \
  --job-name iot-telemetry-asa \
  --name Transformation \
  --streaming-units 1 \
  --saql "SELECT CAST(messageId AS bigint) AS messageId, CAST(deviceId AS nvarchar(max)) AS deviceId, CAST(temperature AS float) AS temperature, CAST(humidity AS float) AS humidity, EventEnqueuedUtcTime AS enqueuedTimeUtc INTO [blobOutput] FROM [iotHubInput]"
```

---

## Step 7 — Start the Stream Analytics job

### Portal

1. In the Stream Analytics job overview click **Start**.
2. Choose **Now** as the output start time (or a specific time to replay historical events).
3. Click **Start** and wait for the **Status** to show **Running**.

### Azure CLI

```bash
az stream-analytics job start \
  --resource-group <RESOURCE_GROUP> \
  --name iot-telemetry-asa \
  --output-start-mode JobStartTime
```

---

## Step 8 — Verify clean output blobs

After your IoT simulator sends a few messages, open **Storage Account → Containers → `telemetry-decoded`** in the portal (or use CLI below) and download a file. Its contents should look like:

```json
{"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":30.85,"humidity":63.84,"enqueuedTimeUtc":"2026-04-28T15:28:48.198Z"}
{"messageId":2,"deviceId":"Raspberry Pi Web Client","temperature":31.93,"humidity":75.77,"enqueuedTimeUtc":"2026-04-28T15:28:49.558Z"}
```

Each line is a valid, standalone JSON object with real numeric fields — no Base64, no envelope.

### Azure CLI — list blobs

```bash
az storage blob list \
  --account-name <STORAGE_ACCOUNT_NAME> \
  --container-name telemetry-decoded \
  --auth-mode login \
  --output table
```

### Azure CLI — download and inspect one blob

```bash
az storage blob download \
  --account-name <STORAGE_ACCOUNT_NAME> \
  --container-name telemetry-decoded \
  --name <BLOB_NAME> \
  --file /tmp/check.json \
  --auth-mode login

cat /tmp/check.json
```

If the file shows numeric `temperature` values (not `null`, not a Base64 string), the ASA pipeline is working correctly.

---

## Step 9 — Configure Azure AI Search to index `telemetry-decoded`

### 9a — Update (or create) the index schema

Ensure the index has the following fields. The critical types are `Edm.Double` for temperature/humidity and `Edm.DateTimeOffset` for the timestamp.

```json
{
  "name": "iot-telemetry-index",
  "fields": [
    { "name": "id",               "type": "Edm.String",        "key": true,  "retrievable": true },
    { "name": "messageId",        "type": "Edm.Int64",         "filterable": true,  "sortable": true,  "retrievable": true },
    { "name": "deviceId",         "type": "Edm.String",        "filterable": true,  "searchable": true, "retrievable": true },
    { "name": "temperature",      "type": "Edm.Double",        "filterable": true,  "sortable": true,  "retrievable": true },
    { "name": "humidity",         "type": "Edm.Double",        "filterable": true,  "sortable": true,  "retrievable": true },
    { "name": "enqueuedTimeUtc",  "type": "Edm.DateTimeOffset","filterable": true,  "sortable": true,  "retrievable": true }
  ]
}
```

> If you already have an index with these fields as the wrong type (e.g. `temperature` as `Edm.String`), you must **delete and recreate** the index — AI Search does not support changing field types in-place.

### REST API — create/update index

```bash
curl -X PUT \
  "https://<SEARCH_SERVICE_NAME>.search.windows.net/indexes/iot-telemetry-index?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <SEARCH_ADMIN_KEY>" \
  -d '{
    "name": "iot-telemetry-index",
    "fields": [
      { "name": "id",              "type": "Edm.String",        "key": true,  "retrievable": true },
      { "name": "messageId",       "type": "Edm.Int64",         "filterable": true,  "sortable": true,  "retrievable": true },
      { "name": "deviceId",        "type": "Edm.String",        "filterable": true,  "searchable": true, "retrievable": true },
      { "name": "temperature",     "type": "Edm.Double",        "filterable": true,  "sortable": true,  "retrievable": true },
      { "name": "humidity",        "type": "Edm.Double",        "filterable": true,  "sortable": true,  "retrievable": true },
      { "name": "enqueuedTimeUtc", "type": "Edm.DateTimeOffset","filterable": true,  "sortable": true,  "retrievable": true }
    ]
  }'
```

### 9b — Create the datasource pointing to `telemetry-decoded`

```bash
curl -X POST \
  "https://<SEARCH_SERVICE_NAME>.search.windows.net/datasources?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <SEARCH_ADMIN_KEY>" \
  -d '{
    "name": "telemetry-decoded-datasource",
    "type": "azureblob",
    "credentials": {
      "connectionString": "DefaultEndpointsProtocol=https;AccountName=<STORAGE_ACCOUNT_NAME>;AccountKey=<STORAGE_ACCOUNT_KEY>;EndpointSuffix=core.windows.net"
    },
    "container": {
      "name": "telemetry-decoded"
    }
  }'
```

### 9c — Create the indexer with `parsingMode: jsonLines`

```bash
curl -X POST \
  "https://<SEARCH_SERVICE_NAME>.search.windows.net/indexers?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: <SEARCH_ADMIN_KEY>" \
  -d '{
    "name": "telemetry-decoded-indexer",
    "dataSourceName": "telemetry-decoded-datasource",
    "targetIndexName": "iot-telemetry-index",
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
    ]
  }'
```

> **Key points:**
> - `parsingMode: jsonLines` tells the indexer to treat each line of the blob as a separate JSON document.
> - No field mappings are needed for `messageId`, `deviceId`, `temperature`, `humidity`, or `enqueuedTimeUtc` because their names already match the index fields exactly.
> - Only the `id` field needs a mapping because it is generated from the blob storage path.

### Portal — create datasource and indexer via Import data wizard

1. Open your Azure AI Search service.
2. Select **Import data**.
3. **Data source**: Azure Blob Storage → select your storage account → container `telemetry-decoded`.
4. **Add cognitive skills**: skip.
5. **Customize target index**: set field types as described in step 9a.
6. **Create an indexer**:
   - Expand **Advanced options** → **Parsing mode** → select `jsonLines`.
   - Schedule: every 5 minutes (or on-demand for testing).
7. Click **Submit**.

---

## Step 10 — Reset and run the indexer

Whenever you change the datasource, index schema, or parsingMode, you must reset the indexer so it reprocesses all blobs.

### Portal

1. Go to your AI Search service → **Indexers** → select `telemetry-decoded-indexer`.
2. Click **Reset** → confirm.
3. Click **Run**.
4. Wait for status to show **Success**.

### REST API

```bash
# Reset
curl -X POST \
  "https://<SEARCH_SERVICE_NAME>.search.windows.net/indexers/telemetry-decoded-indexer/reset?api-version=2023-11-01" \
  -H "api-key: <SEARCH_ADMIN_KEY>"

# Run
curl -X POST \
  "https://<SEARCH_SERVICE_NAME>.search.windows.net/indexers/telemetry-decoded-indexer/run?api-version=2023-11-01" \
  -H "api-key: <SEARCH_ADMIN_KEY>"

# Check status
curl -X GET \
  "https://<SEARCH_SERVICE_NAME>.search.windows.net/indexers/telemetry-decoded-indexer/status?api-version=2023-11-01" \
  -H "api-key: <SEARCH_ADMIN_KEY>"
```

---

## Step 11 — Validate with AI Search Explorer

Open your AI Search service → **Indexes** → `iot-telemetry-index` → **Search explorer**.

### Test 1: All documents

```
search=*
```

Expected: documents with non-null `temperature`, `humidity`, `messageId`, and `deviceId`.

### Test 2: High-temperature filter

```
$filter=temperature gt 30&$orderby=enqueuedTimeUtc desc
```

Expected: documents where `temperature > 30`.

### Test 3: REST API equivalent

```bash
curl -G \
  "https://<SEARCH_SERVICE_NAME>.search.windows.net/indexes/iot-telemetry-index/docs" \
  --data-urlencode "\$filter=temperature gt 30" \
  --data-urlencode "\$orderby=enqueuedTimeUtc desc" \
  --data-urlencode "api-version=2023-11-01" \
  -H "api-key: <SEARCH_QUERY_KEY>"
```

A response like the following confirms the pipeline is working end-to-end:

```json
{
  "value": [
    {
      "id": "...",
      "messageId": 2,
      "deviceId": "Raspberry Pi Web Client",
      "temperature": 31.93,
      "humidity": 75.77,
      "enqueuedTimeUtc": "2026-04-28T15:28:49.558Z"
    }
  ]
}
```

---

## Step 12 — Azure AI Foundry agent configuration

With temperature values now correctly indexed, update your Foundry agent to query the index.

### Recommended agent system prompt (example)

```
You monitor IoT telemetry from a Raspberry Pi device.
Use the Azure AI Search tool to query the index "iot-telemetry-index".
When asked for anomalies, filter for temperature > 30.
Return the most recent matching records ordered by enqueuedTimeUtc descending.
If any records are found, call the alert tool to notify the operations team.
```

### Agent search tool configuration

- **Index**: `iot-telemetry-index`
- **Fields to retrieve**: `messageId`, `deviceId`, `temperature`, `humidity`, `enqueuedTimeUtc`
- **Default filter**: `temperature gt 30`
- **Top**: 10 (or as appropriate)

---

## Step 13 — Logic App alert setup

Your Logic App should expose an **HTTP trigger** and send alerts when the Foundry agent detects anomalies.

### Minimal Logic App workflow

1. **Trigger**: When an HTTP request is received (method: POST).
2. **Action**: Send an email (Outlook/Office 365 or SendGrid) with the payload body.

### Expected payload from the agent

```json
{
  "messageId": 2,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 31.93,
  "humidity": 75.77,
  "enqueuedTimeUtc": "2026-04-28T15:28:49.558Z",
  "alert": "Temperature exceeded 30°C threshold"
}
```

### Configure the Logic App HTTP trigger schema

In the **When an HTTP request is received** trigger, set the request body JSON schema:

```json
{
  "type": "object",
  "properties": {
    "messageId":       { "type": "integer" },
    "deviceId":        { "type": "string"  },
    "temperature":     { "type": "number"  },
    "humidity":        { "type": "number"  },
    "enqueuedTimeUtc": { "type": "string"  },
    "alert":           { "type": "string"  }
  }
}
```

After saving the Logic App, copy the **HTTP POST URL** and configure it as the alert endpoint in your Foundry agent's tool definition.

---

## Validation Checklist

Run through this checklist to confirm each stage of the pipeline is working:

- [ ] **IoT Hub** — device is registered and simulator is sending messages
- [ ] **Consumer group** — `asa-to-search` appears in IoT Hub Built-in endpoints
- [ ] **ASA job** — status is **Running**; **Input events** counter is increasing in the Monitoring tab
- [ ] **ASA output** — blobs appear in `telemetry-decoded` container within ~1 minute of messages being sent
- [ ] **Blob content** — each line in the blob is valid JSON with a numeric `temperature` field (not null, not Base64)
- [ ] **AI Search indexer** — last run status is **Success**; items processed > 0
- [ ] **Search Explorer** — `$filter=temperature gt 30` returns documents with real temperature values
- [ ] **Foundry agent** — agent correctly reports high-temperature readings when queried
- [ ] **Logic App** — HTTP POST to the trigger URL returns 200 and sends the expected alert

---

## Troubleshooting

### Fields are still `null` in AI Search after switching to `telemetry-decoded`

| Cause | Fix |
|---|---|
| Wrong `parsingMode` | Make sure the indexer uses `parsingMode: jsonLines` (not `json` or `text`) |
| Indexer not reset | Click **Reset** then **Run** on the indexer; skip the reset and it may not reprocess existing blobs |
| Stale index schema | If field types were wrong (e.g. `temperature` as string), delete and recreate the index |
| Blobs from old container still being indexed | Confirm the datasource `container` property is `telemetry-decoded`, not `telemetry-raw` or `telemetry` |
| No blobs in `telemetry-decoded` | ASA job may not be running or the output container name has a typo — check ASA **Monitoring → Output events** |

### ASA job fails to start or shows 0 input events

| Cause | Fix |
|---|---|
| Wrong consumer group | Verify the input uses `asa-to-search` not `$Default` |
| IoT Hub key mismatch | Re-enter the `iothubowner` primary key in the ASA input |
| Simulator not sending | Check the IoT simulator — ensure it is connected and the device key is valid |
| ASA provisioning delay | Wait 1–2 minutes after clicking **Start** before expecting events |

### Indexer reports "Could not parse document" warnings

| Cause | Fix |
|---|---|
| Blob is not line-separated JSON | Check ASA output serialization is `JSON / Line separated` (not `Array`) |
| Empty blobs | ASA may write an empty blob at the start of a time window; these are harmless |
| Encoding issues | Ensure ASA output encoding is `UTF-8` |

### AI Search returns HTTP 400 on filter query

| Cause | Fix |
|---|---|
| `temperature` field is not filterable | Ensure `filterable: true` on the field definition |
| Wrong OData syntax | Use `temperature gt 30` (not `temperature > 30`) |

### Logic App alert not firing

| Cause | Fix |
|---|---|
| Agent not calling the HTTP tool | Check agent logs in Azure AI Foundry; add explicit instructions to call the tool |
| Wrong HTTP trigger URL | Regenerate the URL in Logic App and update the agent tool definition |
| CORS or auth error | For a public POC, the Logic App trigger URL already embeds a SAS token — use it as-is |

---

## Quick Reference: Key Resource Names

| Resource | Suggested name |
|---|---|
| IoT Hub consumer group | `asa-to-search` |
| Storage container | `telemetry-decoded` |
| Stream Analytics job | `iot-telemetry-asa` |
| ASA input alias | `iotHubInput` |
| ASA output alias | `blobOutput` |
| AI Search index | `iot-telemetry-index` |
| AI Search datasource | `telemetry-decoded-datasource` |
| AI Search indexer | `telemetry-decoded-indexer` |
