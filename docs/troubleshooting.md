# Troubleshooting Guide — Azure IoT + AI Agent Temperature Monitoring

This guide explains the most common root causes and fixes when the AI agent
reports **"no temperature readings above 30 °C"** even though the IoT device
simulator is sending high-temperature payloads.

---

## Table of Contents

1. [Understanding the IoT Hub Blob Format](#1-understanding-the-iot-hub-blob-format)
2. [Why the Raw Index Returns No Results](#2-why-the-raw-index-returns-no-results)
3. [End-to-End Data Flow](#3-end-to-end-data-flow)
4. [Step-by-Step Diagnostic Checklist](#4-step-by-step-diagnostic-checklist)
5. [Sample Queries to Verify Indexed Values](#5-sample-queries-to-verify-indexed-values)
6. [Common Errors and Fixes](#6-common-errors-and-fixes)
7. [Resetting the Pipeline](#7-resetting-the-pipeline)

---

## 1. Understanding the IoT Hub Blob Format

When Azure IoT Hub routes device-to-cloud messages to Blob Storage using the
**JSON** encoding, the file written to the storage container is a
**newline-delimited sequence of IoT Hub envelope records** — one line per
message.  Each line looks like this:

```json
{
  "EnqueuedTimeUtc": "2026-04-28T10:30:00.000Z",
  "Properties": {},
  "SystemProperties": {
    "connectionDeviceId": "Raspberry Pi Web Client",
    "connectionAuthMethod": "...",
    "enqueuedTime": "2026-04-28T10:30:00.000Z"
  },
  "Body": "eyJtZXNzYWdlSWQiOjEsImRldmljZUlkIjoiUmFzcGJlcnJ5IFBpIFdlYiBDbGllbnQiLCJ0ZW1wZXJhdHVyZSI6MjQuNjI4MjY5NzQ4MTQyNzM1LCJodW1pZGl0eSI6NjEuMjE1MjQ1NjMyNDQzNzc1fQ=="
}
```

> **Key observation:** The `Body` property is **Base64-encoded**.

Decoded, the `Body` above is exactly what the Raspberry Pi Web Simulator sends:

```json
{
  "messageId": 1,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 24.628269748142735,
  "humidity": 61.215245632443775
}
```

Azure AI Search cannot natively decode Base64.  If the indexer targets the raw
`telemetry` container, it indexes the `Body` field as an opaque string — the
`temperature` and `humidity` numbers are never visible to search.

---

## 2. Why the Raw Index Returns No Results

Symptom: the agent says *"I found no temperature readings above 30 °C"* even
though blobs exist in the `telemetry` container with high-temperature data.

**Root cause:** The indexer is reading the IoT Hub envelope records.  The
field `temperature` does not exist at the envelope level — it lives *inside*
the Base64-encoded `Body`.  The search index therefore has no numeric
`temperature` field to filter on, so `$filter=temperature gt 30` always
returns 0 results.

---

## 3. End-to-End Data Flow

```
Raspberry Pi Web Simulator
        │  JSON payload (messageId, deviceId, temperature, humidity)
        ▼
Azure IoT Hub  (S1)
        │  Wraps payload in envelope; Base64-encodes Body
        │  Routes to Blob Storage → container: telemetry/
        ▼
Blob Storage — container: telemetry/
        │  Newline-delimited envelope records (Body = Base64)
        ▼
Azure Function: telemetry-decoder  ◄── THIS IS THE KEY STEP
        │  Blob trigger on telemetry/{name}
        │  For each line:
        │    1. Parse envelope JSON
        │    2. Base64-decode Body
        │    3. Parse decoded JSON → temperature, humidity, etc.
        │    4. Write flat JSON record with stable `id`
        ▼
Blob Storage — container: telemetry-processed/
        │  Newline-delimited clean JSON records (temperature is a number)
        ▼
Azure AI Search Indexer
        │  parsingMode = jsonLines
        │  Targets telemetry-processed container
        ▼
Index: iot-telemetry-index
        │  temperature, humidity, deviceId, messageId are all indexed
        ▼
AI Agent
        │  $filter=temperature gt 30
        ▼
Logic App → Email alert
```

---

## 4. Step-by-Step Diagnostic Checklist

### Step 1 — Verify the simulator is sending data

Open the browser console of the Raspberry Pi Web Simulator.  You should see:

```
Sending message: {"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":35.7,"humidity":62.1}
```

If you do not see this, check the device connection string.

---

### Step 2 — Verify blobs are arriving in the `telemetry` container

```bash
az storage blob list \
  --container-name telemetry \
  --account-name YOUR_STORAGE_ACCOUNT \
  --output table
```

Expected: blobs with paths like
`YOUR_IOT_HUB/0/2026/04/28/10/30/<uuid>.json`.

If no blobs appear after 2 minutes, check the IoT Hub **Message routing** →
confirm the route exists, the endpoint points to the correct storage container,
and the route query is `true`.

---

### Step 3 — Inspect a raw blob to confirm the Base64 Body

```bash
az storage blob download \
  --container-name telemetry \
  --name "YOUR_IOT_HUB/0/2026/04/28/10/30/sample.json" \
  --account-name YOUR_STORAGE_ACCOUNT \
  --file /tmp/sample.json

cat /tmp/sample.json
```

You should see records with a `Body` field containing a Base64 string.

Decode it manually to verify:

```bash
# Extract the Body from the first record and decode it
node -e "
const fs = require('fs');
const line = fs.readFileSync('/tmp/sample.json','utf8').split('\n')[0];
const envelope = JSON.parse(line);
console.log(JSON.parse(Buffer.from(envelope.Body,'base64').toString('utf8')));
"
```

Expected output:
```json
{
  "messageId": 1,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 35.7,
  "humidity": 62.1
}
```

---

### Step 4 — Verify the `telemetry-decoder` Function is running

In the Azure Portal:

1. Navigate to your Function App → **Functions** → `telemetry-decoder`
2. Click **Monitor** → check for recent invocations
3. Each blob arrival should trigger an invocation
4. Check for errors in the logs

If the function has not been deployed, follow the deployment steps in
`README.md` (Phase 2 — Azure Function Deployment).

---

### Step 5 — Verify the `telemetry-processed` container has clean records

```bash
az storage blob list \
  --container-name telemetry-processed \
  --account-name YOUR_STORAGE_ACCOUNT \
  --output table
```

Download a file and inspect it:

```bash
az storage blob download \
  --container-name telemetry-processed \
  --name "YOUR_BLOB_NAME.json" \
  --account-name YOUR_STORAGE_ACCOUNT \
  --file /tmp/processed.json

cat /tmp/processed.json
```

Each line should be a flat JSON record like:

```json
{"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":35.7,"humidity":62.1,"timestamp":"2026-04-28T10:30:00.000Z","enqueuedTimeUtc":"2026-04-28T10:30:00.000Z","id":"UmFzcGJlcnJ5..."}
```

If this file is missing or empty, the Function is not running correctly.

---

### Step 6 — Check the Azure AI Search indexer status

```bash
curl -s \
  "https://YOUR_SEARCH_SERVICE.search.windows.net/indexers/telemetry-indexer/status?api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool
```

Look for:
* `"status": "running"` — indexer is active
* `"lastResult.status": "success"` — last run succeeded
* `"lastResult.itemsProcessed"` — should be > 0

If `lastResult.status` is `"transientFailure"` or `"persistentFailure"`, check
`lastResult.errors` for details.

---

### Step 7 — Manually trigger the indexer

```bash
curl -X POST \
  "https://YOUR_SEARCH_SERVICE.search.windows.net/indexers/telemetry-indexer/run?api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY"
```

Wait 30 seconds, then proceed to Step 8.

---

### Step 8 — Run verification queries

See [Section 5](#5-sample-queries-to-verify-indexed-values) below.

---

## 5. Sample Queries to Verify Indexed Values

Replace `YOUR_SEARCH_SERVICE` and `YOUR_ADMIN_KEY` with your actual values.

### Count all indexed records

```bash
curl -s \
  "https://YOUR_SEARCH_SERVICE.search.windows.net/indexes/iot-telemetry-index/docs?\$count=true&search=*&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool
```

Expected: `"@odata.count"` > 0.

---

### Find all readings with temperature > 30 °C

```bash
curl -s \
  "https://YOUR_SEARCH_SERVICE.search.windows.net/indexes/iot-telemetry-index/docs?\$filter=temperature+gt+30&\$orderby=temperature+desc&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool
```

Expected: a list of records whose `temperature` field is a **number** greater
than 30.

If the response contains records but `temperature` is `null` or the response
is empty while you know high-temperature data exists, the indexer is still
targeting the raw `telemetry` container.  Update the data source to point to
`telemetry-processed` (see `search/datasource-config.json`).

---

### Find the 10 most recent readings

```bash
curl -s \
  "https://YOUR_SEARCH_SERVICE.search.windows.net/indexes/iot-telemetry-index/docs?search=*&\$orderby=timestamp+desc&\$top=10&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool
```

---

### Find readings for a specific device above threshold

```bash
DEVICE="Raspberry Pi Web Client"
ENCODED_DEVICE=$(python3 -c "import urllib.parse; print(urllib.parse.quote(\"$DEVICE\"))")

curl -s \
  "https://YOUR_SEARCH_SERVICE.search.windows.net/indexes/iot-telemetry-index/docs?\$filter=deviceId+eq+'${ENCODED_DEVICE}'+and+temperature+gt+30&\$orderby=timestamp+desc&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | python3 -m json.tool
```

---

### Verify temperature distribution (min/max/average)

Azure AI Search does not support aggregations natively, but you can retrieve
all records and compute statistics with:

```bash
curl -s \
  "https://YOUR_SEARCH_SERVICE.search.windows.net/indexes/iot-telemetry-index/docs?search=*&\$select=temperature,humidity,deviceId,timestamp&\$top=1000&api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY" | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
temps = [d['temperature'] for d in data['value'] if d.get('temperature') is not None]
print(f'Records: {len(temps)}')
print(f'Min temperature: {min(temps):.2f} °C')
print(f'Max temperature: {max(temps):.2f} °C')
print(f'Avg temperature: {sum(temps)/len(temps):.2f} °C')
print(f'Above 30 °C: {sum(1 for t in temps if t > 30)}')
"
```

---

## 6. Common Errors and Fixes

### Error: `$filter=temperature gt 30` returns 0 results

| Possible cause | Fix |
|---|---|
| Indexer targeting raw `telemetry` container | Update `search/datasource-config.json` to target `telemetry-processed`; recreate datasource and rerun indexer |
| `telemetry-decoder` Function not deployed | Deploy the Function from `functions/telemetry-decoder/` |
| `telemetry-processed` container does not exist | Create it: `az storage container create --name telemetry-processed --account-name YOUR_STORAGE_ACCOUNT` |
| Indexer has never run | Trigger manually: see Step 7 above |
| Index schema missing `temperature` field | Delete and recreate index using `search/index-schema.json` |

---

### Error: Indexer status shows `"fieldMappingError"`

The indexer cannot map `temperature` because the field does not exist in the
document.  This means the indexer is reading the raw `telemetry` blobs (where
`temperature` is inside the Base64 `Body`, not at the root level).  Fix: point
the datasource at `telemetry-processed`.

---

### Error: Function invocations show `"Failed to decode/parse Body"`

The blob contains lines that are not valid IoT Hub envelope JSON.  This can
happen if the IoT Hub routing **Encoding** was set to **Avro** instead of
**JSON**.  In the Azure Portal, navigate to IoT Hub → **Message routing** →
**Endpoints** → your storage endpoint → change **Encoding** to **JSON**.

---

### Error: Agent still reports no high temperatures after all fixes

1. Confirm the index contains records: run the count query above.
2. Confirm at least one `temperature` value is > 30 in the index.
3. Check the agent's system prompt — it must use `$filter=temperature gt 30`,
   not a full-text keyword search.
4. Verify the agent's data source configuration points to `iot-telemetry-index`
   on the correct Azure AI Search service.

---

## 7. Resetting the Pipeline

If you need a clean start:

```bash
# 1. Delete and recreate the processed container
az storage container delete --name telemetry-processed --account-name YOUR_STORAGE_ACCOUNT
az storage container create  --name telemetry-processed --account-name YOUR_STORAGE_ACCOUNT

# 2. Delete and recreate the search index
az search index delete    --service-name YOUR_SEARCH_SERVICE --name iot-telemetry-index --resource-group YOUR_RG
az search index create    --service-name YOUR_SEARCH_SERVICE --resource-group YOUR_RG --parameters @search/index-schema.json

# 3. Delete and recreate the datasource
# (replace with curl commands using the REST API — see README.md)

# 4. Delete and recreate the indexer
# (replace with curl commands using the REST API — see README.md)

# 5. Restart the Function App
az functionapp restart --name YOUR_FUNCTION_APP --resource-group YOUR_RG

# 6. Wait for the Function to process existing blobs, then rerun the indexer
curl -X POST \
  "https://YOUR_SEARCH_SERVICE.search.windows.net/indexers/telemetry-indexer/run?api-version=2023-11-01" \
  -H "api-key: YOUR_ADMIN_KEY"
```
