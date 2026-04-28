# Azure IoT + AI Agent Temperature Monitoring Demo

End-to-end proof-of-concept that streams telemetry from an IoT simulator through **Azure IoT Hub → Blob Storage → Azure AI Search → Azure AI Foundry Agent → Logic App email alert**.

---

## Architecture

```
Raspberry Pi Simulator
        │  JSON telemetry over MQTT
        ▼
  Azure IoT Hub
        │  message routing
        ▼
  Azure Blob Storage  ←──────────────────────────┐
  (container: telemetry-jsonlines)               │
        │  blob indexer (jsonLines mode)         │
        ▼                                        │
  Azure AI Search                                │
  (index: iot-telemetry-index)                  │
        │  knowledge-base tool                   │
        ▼                                        │
  Azure AI Foundry Agent  ──── HTTP POST ────► Logic App ──► Email alert
```

---

## Pre-requisites

| Resource | Notes |
|---|---|
| Azure subscription | Free tier works for PoC |
| Azure IoT Hub | Free or S1 tier |
| Azure Blob Storage account | General Purpose v2 |
| Azure AI Search | Basic tier or above |
| Azure AI Foundry project | With GPT-4 deployment |
| Azure Logic App | Consumption plan |

---

## Quick Start

### Phase 1 – IoT Hub & Device

#### Step 1 – Create IoT Hub

```bash
az iot hub create \
  --name my-iot-hub-demo \
  --resource-group my-rg \
  --sku F1 --partition-count 2
```

#### Step 2 – Register device

```bash
az iot hub device-identity create \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator
```

Copy the connection string:

```bash
az iot hub device-identity connection-string show \
  --hub-name my-iot-hub-demo \
  --device-id raspberry-pi-simulator \
  --query connectionString -o tsv
```

#### Step 3 – Run the simulator

1. Open [Raspberry Pi Web Simulator](https://azure-samples.github.io/raspberry-pi-web-simulator/#GetStarted).
2. Replace `[Your IoT hub device connection string]` on line 15 with the connection string from Step 2.
3. Click **Run**.

You should see output like:

```
Sending message: {"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":24.63,"humidity":61.22}
Message sent successfully.
```

---

### Phase 2 – Blob Storage

#### Step 4 – Create storage account & container

```bash
az storage account create \
  --name iotaidemo12345 \
  --resource-group my-rg \
  --sku Standard_LRS

az storage container create \
  --name telemetry-jsonlines \
  --account-name iotaidemo12345
```

> **Important – use the `telemetry-jsonlines` container** (not `telemetry`).  
> The datasource config and indexer both target this container.

#### Step 5 – Configure IoT Hub message routing

In the Azure Portal:

1. Navigate to your IoT Hub → **Message routing** → **Routes** → **+ Add**.
2. Set **Endpoint** → create a new **Storage** endpoint:
   - Container: `telemetry-jsonlines`
   - File name format: `{iothub}/{YYYY}/{MM}/{DD}/{HH}/{mm}`
   - Encoding: **JSON** *(not AVRO)*
   - Batch frequency: 60 seconds (minimum)
3. **Routing query**: `true` (route all messages)
4. Click **Save**.

> **Why JSON encoding matters**: The `jsonLines` parsing mode in Azure AI Search expects each message to be on its own line in UTF-8 with no BOM. Selecting **JSON** encoding in the routing endpoint produces exactly this format. AVRO produces binary files that the indexer cannot parse.

#### Step 6 – Verify blobs are written

Wait ~2 minutes, then:

```bash
az storage blob list \
  --container-name telemetry-jsonlines \
  --account-name iotaidemo12345 \
  --output table
```

Download a sample blob to inspect it:

```bash
az storage blob download \
  --container-name telemetry-jsonlines \
  --name "my-iot-hub-demo/0/2026/04/28/14/30/00.json" \
  --account-name iotaidemo12345 \
  --file /tmp/sample.json

cat /tmp/sample.json
```

Expected content (one JSON object per line, **no BOM**, UTF-8):

```json
{"messageId":5,"deviceId":"Raspberry Pi Web Client","temperature":27.84,"humidity":73.74}
{"messageId":6,"deviceId":"Raspberry Pi Web Client","temperature":28.11,"humidity":72.50}
```

---

### Phase 3 – Azure AI Search

#### Step 7 – Create Search service

```bash
az search service create \
  --name my-ai-search-demo \
  --resource-group my-rg \
  --sku basic
```

Copy the **admin key**:

```bash
az search admin-key show \
  --service-name my-ai-search-demo \
  --resource-group my-rg \
  --query primaryKey -o tsv
```

#### Step 8 – Set environment variables

```bash
export SEARCH_ENDPOINT="https://my-ai-search-demo.search.windows.net"
export SEARCH_ADMIN_KEY="<admin-key-from-above>"
export STORAGE_CONNECTION_STRING="$(az storage account show-connection-string \
  --name iotaidemo12345 --resource-group my-rg --query connectionString -o tsv)"
export STORAGE_CONTAINER="telemetry-jsonlines"
```

#### Step 9 – Create index

Schema is in [`search/index-schema.json`](search/index-schema.json).

Key decisions:

| Field | Type | Reason |
|---|---|---|
| `id` | `Edm.String` (key) | Generated from blob path via `base64Encode` |
| `messageId` | `Edm.Int32` | Simulator sends integer |
| `deviceId` | `Edm.String` | `"Raspberry Pi Web Client"` |
| `temperature` | `Edm.Double` | Float value |
| `humidity` | `Edm.Double` | Float value |
| `enqueuedTime` | `Edm.DateTimeOffset` | Mapped from blob metadata |

```bash
curl -X POST \
  "${SEARCH_ENDPOINT}/indexes?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" \
  -d @search/index-schema.json
```

#### Step 10 – Create datasource

The datasource config is in [`search/datasource-config.json`](search/datasource-config.json).  
Substitute real credentials when creating it:

```bash
cat search/datasource-config.json \
  | python3 -c "
import sys, json, os
d = json.load(sys.stdin)
d['credentials']['connectionString'] = os.environ['STORAGE_CONNECTION_STRING']
d['container']['name'] = os.environ['STORAGE_CONTAINER']
print(json.dumps(d))
" | curl -X POST \
  "${SEARCH_ENDPOINT}/datasources?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" \
  -d @-
```

#### Step 11 – Create indexer

The indexer config is in [`search/indexer-config.json`](search/indexer-config.json).

**Key configuration decisions (why things work now):**

| Setting | Value | Why |
|---|---|---|
| `parsingMode` | `"jsonLines"` | Each IoT Hub routing file contains **multiple** JSON objects, one per line. `json` mode would try to parse the whole file as a single document and fail. |
| `dataToExtract` | `"contentAndMetadata"` | Extracts JSON content **plus** blob metadata (needed for `enqueuedTime`). |
| `fieldMappings` for content fields | **None needed** | With `jsonLines` mode the indexer automatically maps JSON properties to index fields with the **same name**. Explicit `/messageId` path-expression mappings (using JSON Pointer syntax) only apply to `parsingMode: "json"` and would cause null fields in `jsonLines` mode. |
| `id` mapping | `metadata_storage_path` + `base64Encode` | Generates a unique key per document (line) from the blob path. |
| `enqueuedTime` mapping | `metadata_storage_last_modified` | The telemetry JSON itself does not contain a timestamp. `metadata_storage_last_modified` is the time the blob was written to storage — an approximation within the routing batch window (default 60 s). For exact IoT Hub receive times, add an `enqueuedTime` field to the device message payload and remove this mapping. |

```bash
curl -X POST \
  "${SEARCH_ENDPOINT}/indexers?api-version=2023-11-01" \
  -H "Content-Type: application/json" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" \
  -d @search/indexer-config.json
```

Trigger an immediate run:

```bash
curl -X POST \
  "${SEARCH_ENDPOINT}/indexers/telemetry-indexer/run?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}"
```

Or use the **all-in-one script** (creates/recreates everything from scratch):

```bash
bash scripts/setup-search.sh
```

#### Step 12 – Verify indexer & query results

Check indexer status (look for `"status": "success"` and zero `"itemsFailed"`):

```bash
curl -s \
  "${SEARCH_ENDPOINT}/indexers/telemetry-indexer/status?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" | python3 -m json.tool
```

Query the index:

```bash
curl -s \
  "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index/docs?api-version=2023-11-01&search=*&\$top=5" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" | python3 -m json.tool
```

Expected response:

```json
{
  "value": [
    {
      "id": "aHR0cHM...",
      "messageId": 5,
      "deviceId": "Raspberry Pi Web Client",
      "temperature": 27.84,
      "humidity": 73.74,
      "enqueuedTime": "2026-04-28T14:30:00Z"
    }
  ]
}
```

---

### Phase 4 – Logic App

#### Step 13 – Create Logic App

```bash
az logic workflow create \
  --name iot-alert-app \
  --resource-group my-rg \
  --location australiaeast
```

Or create via the Azure Portal (Consumption plan).

#### Step 14 – Configure Logic App workflow

1. Open the Logic App → **Logic app designer**.

2. **Add HTTP trigger**: search for *"When a HTTP request is received"*.

   Paste this **Request Body JSON Schema**:

   ```json
   {
     "type": "object",
     "properties": {
       "messageId": { "type": "integer" },
       "deviceId": { "type": "string" },
       "temperature": { "type": "number" },
       "humidity": { "type": "number" },
       "enqueuedTime": { "type": "string" }
     },
     "required": ["messageId", "deviceId", "temperature", "humidity"]
   }
   ```

3. **Add Parse JSON action**: use the same schema; set **Content** to the trigger's `Body`.

4. **Add Condition**: `temperature` (from Parse JSON) **is greater than** `30`.

5. **True branch – Send email (V2)**:
   - **To:** your email address
   - **Subject:** `🚨 Temperature Alert - Device: @{body('Parse_JSON')?['deviceId']}`
   - **Body:**
     ```
     🌡️ TEMPERATURE ALERT DETECTED!
     
     Device ID:   @{body('Parse_JSON')?['deviceId']}
     Message ID:  @{body('Parse_JSON')?['messageId']}
     Temperature: @{body('Parse_JSON')?['temperature']}°C
     Humidity:    @{body('Parse_JSON')?['humidity']}%
     Time:        @{body('Parse_JSON')?['enqueuedTime']}
     
     ⚠️ Temperature threshold (30°C) has been exceeded!
     ```

6. **Save** and copy the **HTTP POST URL** — you will need it in Steps 19–20.

#### Step 15 – Test Logic App directly

```bash
curl -X POST "YOUR_LOGIC_APP_CALLBACK_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "messageId": 999,
    "deviceId": "Raspberry Pi Web Client",
    "temperature": 35.5,
    "humidity": 60.2,
    "enqueuedTime": "2026-04-28T10:30:00Z"
  }'
```

You should receive an email within ~30 seconds.

---

### Phase 5 – Azure AI Foundry Agent

#### Step 16 – Create AI Foundry project & deploy model

1. Go to [Azure AI Foundry](https://ai.azure.com/) → **+ New project**.
2. Deploy a **GPT-4** model (or GPT-4o). Note the deployment name (e.g. `gpt-4-deployment`).

#### Step 17 – Create the agent

1. In your project, go to **Agents** → **+ Create agent**.
2. Select your GPT-4 deployment.
3. **System prompt**:

```
You are an IoT temperature monitoring agent for the "Raspberry Pi Web Client" device.

Your responsibilities:
1. Monitor telemetry data using Azure AI Search as your knowledge base.
2. Query the search index for recent temperature readings from deviceId: "Raspberry Pi Web Client".
3. When temperature > 30°C is detected, immediately call trigger_temperature_alert.
4. Include messageId, deviceId, temperature, humidity, and enqueuedTime in all alerts.

Device message structure:
- messageId: integer (sequential)
- deviceId: "Raspberry Pi Web Client"
- temperature: float (Celsius)
- humidity: float (percentage)
- enqueuedTime: datetime (when IoT Hub received the message)
```

#### Step 18 – Connect Azure AI Search as a knowledge base

In the agent configuration:
1. Add a **Knowledge** tool → select **Azure AI Search**.
2. Choose your search service and select index `iot-telemetry-index`.
3. Configure the tool to query on semantic or keyword search.

#### Step 19 – Add the Logic App as a generic HTTP tool

In the agent configuration add a **Generic HTTP** tool (Action):

| Field | Value |
|---|---|
| Name | `trigger_temperature_alert` |
| Description | Triggers an alert when temperature > 30°C |
| Method | `POST` |
| URL | *(paste the full Logic App callback URL including `sig` query param)* |
| Headers | `Content-Type: application/json` |
| Body | See below |

**Request body template** (all values filled by the agent at runtime):

```json
{
  "messageId": 0,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 0.0,
  "humidity": 0.0,
  "enqueuedTime": "2026-04-28T00:00:00Z"
}
```

> **Why not the OpenAPI wrapper shape?**  
> Some tools auto-generate an OpenAPI spec with `HTTP_URI` / `HTTP_request_content` fields. That is a *generic HTTP proxy* pattern — the agent would have to embed the real payload as a JSON string inside `HTTP_request_content`, and the Logic App would need an extra Parse JSON step to unwrap it. A **generic HTTP tool** already has the URL and headers configured, so you post the telemetry fields directly as JSON, which is simpler and matches the Logic App trigger schema exactly.

**Agent function definition** (for the function-calling API if used instead of the GUI tool):

```json
{
  "name": "trigger_temperature_alert",
  "description": "Triggers an alert via Logic App when temperature exceeds 30°C.",
  "parameters": {
    "type": "object",
    "properties": {
      "messageId":    { "type": "integer", "description": "Sequential message ID" },
      "deviceId":     { "type": "string",  "description": "IoT device identifier" },
      "temperature":  { "type": "number",  "description": "Temperature in Celsius" },
      "humidity":     { "type": "number",  "description": "Humidity percentage" },
      "enqueuedTime": { "type": "string",  "description": "ISO 8601 timestamp" }
    },
    "required": ["messageId", "deviceId", "temperature", "humidity", "enqueuedTime"]
  }
}
```

#### Step 20 – Test the agent

In the agent chat playground:

```
Check the latest temperature readings from the Raspberry Pi Web Client.
Are there any readings exceeding 30°C? If so, trigger an alert.
```

The agent should:
1. Query `iot-telemetry-index` for high-temperature documents.
2. Call `trigger_temperature_alert` with the retrieved values.
3. You should receive an email alert.

---

### Phase 6 – End-to-End Testing

#### Step 21 – Simulate high temperatures

In the Raspberry Pi Web Simulator, find the temperature line (~line 27) and change it to generate readings above 30°C:

```javascript
// Original
const temperature = 20 + (Math.random() * 15);

// High-temperature simulation
const temperature = 31 + (Math.random() * 10);  // 31–41°C
```

Click **Run**. You should see:

```
Sending message: {"messageId":10,"deviceId":"Raspberry Pi Web Client","temperature":35.8,"humidity":62.3}
Message sent successfully.
```

#### Step 22 – Verify each component

1. **IoT Hub** – monitor live messages:
   ```bash
   az iot hub monitor-events \
     --hub-name my-iot-hub-demo \
     --device-id raspberry-pi-simulator
   ```

2. **Storage** – verify blobs appear:
   ```bash
   az storage blob list \
     --container-name telemetry-jsonlines \
     --account-name iotaidemo12345 \
     --output table
   ```

3. **AI Search** – query for high temperatures:
   ```bash
   curl -s \
     "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index/docs?api-version=2023-11-01&\$filter=temperature%20gt%2030&\$orderby=messageId%20desc&\$top=10" \
     -H "api-key: ${SEARCH_ADMIN_KEY}" | python3 -m json.tool
   ```

4. **Logic App** – check **Runs history** in the Azure Portal.

5. **Email inbox** – check for alert emails.

---

## Troubleshooting

### Indexer shows null fields

**Root cause**: Using `parsingMode: "json"` with explicit `/fieldName` (JSON Pointer) field mappings on a container where each blob has **multiple** JSON objects.

**Fix**:
1. Switch container to one containing plain JSON-lines files (one JSON object per line).
2. Set `parsingMode: "jsonLines"` in the indexer.
3. **Remove** all field mappings that use the `/fieldName` path-expression syntax — with `jsonLines` the indexer matches JSON properties to index fields by name automatically.
4. Keep only the two metadata mappings (`id` from `metadata_storage_path`, `enqueuedTime` from `metadata_storage_last_modified`).
5. Reset and rerun the indexer (see below).

### Check indexer status & errors

```bash
curl -s \
  "${SEARCH_ENDPOINT}/indexers/telemetry-indexer/status?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" | python3 -m json.tool
```

Look at `lastResult.errors` and `lastResult.itemsFailed`. Common messages:

| Error | Cause | Fix |
|---|---|---|
| `Could not find field 'messageId'` | Index schema missing the field | Recreate index with correct schema |
| `Document key is missing` | No `id` field mapping | Add `metadata_storage_path` → `id` with `base64Encode` |
| `Could not parse document` | Wrong `parsingMode` | Switch to `jsonLines` for multi-object blobs |
| `Field mapping ... cannot be applied` | `/fieldName` path expression used in `jsonLines` mode | Remove the leading slash |

### Reset indexer to reprocess all blobs

```bash
# Reset (clears high-water mark so all blobs are re-indexed)
curl -X POST \
  "${SEARCH_ENDPOINT}/indexers/telemetry-indexer/reset?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}"

# Trigger immediate run
curl -X POST \
  "${SEARCH_ENDPOINT}/indexers/telemetry-indexer/run?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}"
```

### Delete prior index documents (full clean reindex)

Use the setup script which deletes and recreates everything:

```bash
bash scripts/setup-search.sh
```

Or manually:

```bash
# Delete indexer
curl -X DELETE \
  "${SEARCH_ENDPOINT}/indexers/telemetry-indexer?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}"

# Delete datasource
curl -X DELETE \
  "${SEARCH_ENDPOINT}/datasources/telemetry-datasource?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}"

# Delete index (removes all documents)
curl -X DELETE \
  "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}"

# Recreate everything
curl -X POST "${SEARCH_ENDPOINT}/indexes?api-version=2023-11-01" \
  -H "Content-Type: application/json" -H "api-key: ${SEARCH_ADMIN_KEY}" \
  -d @search/index-schema.json

# ... (datasource + indexer as in Steps 10-11)
```

### Verify datasource connection

```bash
curl -s \
  "${SEARCH_ENDPOINT}/datasources/telemetry-datasource?api-version=2023-11-01" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" | python3 -m json.tool
```

Check that `container.name` is `telemetry-jsonlines` and the connection string is correct.

### Blobs in virtual folders vs root

Azure AI Search blob indexing supports virtual folders (path prefixes). You do **not** need blobs in the root. IoT Hub routing writes blobs under a path like `my-iot-hub-demo/0/YYYY/MM/DD/HH/mm/ss.json`, which is fine — the indexer will crawl all blobs in the container recursively.

If you want to restrict to a specific folder, set `container.query` in the datasource:

```json
"container": {
  "name": "telemetry-jsonlines",
  "query": "my-iot-hub-demo/0/2026"
}
```

### JSON stored as `text/plain` or with BOM

IoT Hub routing with **JSON** encoding writes `application/json` blobs without a BOM. If you uploaded JSON files manually and they have a UTF-8 BOM (`EF BB BF`), the indexer will fail to parse them.

To check and strip the BOM:

```bash
# Check
hexdump -C /tmp/sample.json | head -1

# Strip BOM (Linux)
sed -i '1s/^\xEF\xBB\xBF//' /tmp/sample.json
```

### No results for "Raspberry Pi Web Client" (spaces in deviceId)

The device ID contains spaces. Use proper OData filter syntax:

```bash
# Filter
curl -s \
  "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index/docs?api-version=2023-11-01&\$filter=deviceId%20eq%20'Raspberry%20Pi%20Web%20Client'" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" | python3 -m json.tool

# Full-text search
curl -s \
  "${SEARCH_ENDPOINT}/indexes/iot-telemetry-index/docs?api-version=2023-11-01&search=Raspberry%20Pi%20Web%20Client" \
  -H "api-key: ${SEARCH_ADMIN_KEY}" | python3 -m json.tool
```

---

## Repository Structure

```
.
├── README.md
├── scripts/
│   └── setup-search.sh       # Creates/recreates all Azure AI Search resources
└── search/
    ├── datasource-config.json # Blob storage datasource (container: telemetry-jsonlines)
    ├── index-schema.json      # Search index schema
    └── indexer-config.json    # Indexer (parsingMode: jsonLines, correct field mappings)
```

---

## Final Working Configuration Summary

### `search/indexer-config.json` (key fields explained)

```json
{
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
    },
    {
      "sourceFieldName": "metadata_storage_last_modified",
      "targetFieldName": "enqueuedTime"
    }
  ]
}
```

**Why no `messageId`/`deviceId`/`temperature`/`humidity` field mappings?**  
With `parsingMode: "jsonLines"`, the indexer reads each line as an independent JSON document and **automatically maps** every top-level JSON property to an index field with the matching name. Explicit mappings for those fields are not only unnecessary — using the JSON Pointer path syntax (`"/messageId"`) that works in single-document `json` mode will cause the indexer to look for a blob metadata field called `/messageId`, which does not exist, resulting in null values. Remove those mappings and the automatic name-based mapping takes over correctly.

**About `enqueuedTime`:**  
`metadata_storage_last_modified` is the time Azure Blob Storage wrote the file, not the exact time IoT Hub received the message. It is accurate within the routing batch window (default 60 seconds). For exact receive times, add an `enqueuedTime` property to the device message payload and replace the mapping above with a direct content-field mapping (no leading slash needed with `jsonLines`).
