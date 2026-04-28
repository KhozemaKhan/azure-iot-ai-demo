# Troubleshooting Checklist

Use this checklist to diagnose issues at each stage of the
**IoT Hub → Stream Analytics → Blob → AI Search → Foundry Agent** pipeline.

---

## Checklist A — Stream Analytics not producing blobs

- [ ] **Job is in Running state**
  - ASA job → Overview → Status must show **Running** (not Created, Stopped, or Failed).
  - If Failed, open **Activity log** for the error message.

- [ ] **Input events counter is non-zero**
  - ASA job → Monitoring → chart shows **Input events > 0**.
  - If zero: check IoT Hub is receiving messages (IoT Hub → Metrics → D2C messages received).

- [ ] **Consumer group is correct**
  - ASA input must reference the dedicated consumer group (`asa-to-search`), not `$Default`.
  - `$Default` is shared and may have been read by another consumer, leaving no events for ASA.

- [ ] **Query references correct alias names**
  - `FROM [iotHubInput]` must match your input alias exactly (case-sensitive).
  - `INTO [blobOutput]` must match your output alias exactly.

- [ ] **Output container exists**
  - Storage Account → Containers — `telemetry-decoded` must exist before the job writes to it.

- [ ] **Output errors counter is zero**
  - ASA job → Monitoring → **Output errors** should be 0.
  - Errors here often indicate permission issues (Storage Account firewall, missing role assignment).

- [ ] **Stream Analytics Managed Identity has Storage Blob Data Contributor role**
  - If using Managed Identity authentication on the output, the ASA job's identity needs the **Storage Blob Data Contributor** role on the storage account.

---

## Checklist B — Blobs contain unexpected content or wrong types

- [ ] **Blob content is newline-delimited JSON (not Base64)**
  - Open a blob file; each line must start with `{` and end with `}`.
  - If you see Base64 strings or `{"Body":"..."}` wrappers, the data is coming from IoT Hub blob routing (not ASA). Fix: use ASA input from IoT Hub endpoint, not from blob routing output.

- [ ] **Numeric fields are not wrapped in quotes**
  - `"temperature":31.9` (number) vs `"temperature":"31.9"` (string).
  - If string: add explicit `CAST(temperature AS float)` in the ASA query and re-run.

- [ ] **`enqueuedTimeUtc` is present and correctly formatted**
  - Expected: `"enqueuedTimeUtc":"2026-04-28T15:28:49.558Z"`
  - If missing: add `EventEnqueuedUtcTime AS enqueuedTimeUtc` to the SELECT clause.

---

## Checklist C — AI Search indexer not populating fields

- [ ] **Parsing mode is `jsonLines`**
  - Indexer configuration → `parameters.configuration.parsingMode` must be `"jsonLines"`.
  - Using `"json"` (single-document mode) will only read the first line of each blob.
  - Leaving it unset treats the blob as plain text — all JSON fields become `null`.

- [ ] **`dataToExtract` is `contentAndMetadata` (or `allMetadata` for metadata-only needs)**
  - Default `contentAndMetadata` is correct for this pipeline.

- [ ] **Field names in the index match the JSON keys exactly**
  - JSON key `temperature` must map to index field `temperature` (case-sensitive).
  - If names differ, add a `fieldMapping` entry in the indexer.

- [ ] **Field types in the index match the JSON value types**
  - `temperature` must be `Edm.Double` (not `Edm.String`).
  - `messageId` must be `Edm.Int64` or `Edm.Int32` (not `Edm.String`).
  - Type mismatches cause silent field drop or indexer warnings.

- [ ] **Indexer has been reset and re-run after schema changes**
  - Schema changes require: Reset indexer → Run indexer.
  - Without reset, the indexer may skip blobs it previously processed.

- [ ] **No failed items in indexer execution history**
  - AI Search → Indexers → your indexer → **Execution history**.
  - Expand the latest run; expand **Errors / warnings** for per-document diagnostics.

- [ ] **Blob container and datasource are pointing to the correct container**
  - Datasource `container.name` must be `telemetry-decoded`, not the original IoT Hub routing container.

---

## Checklist D — AI Search query returns no results

- [ ] **Index contains documents**
  - Search Explorer: `search=*` — must return at least one document.
  - If empty, the indexer has not processed any blobs yet (see Checklist C).

- [ ] **Temperature filter uses the correct OData syntax**
  - Correct: `$filter=temperature gt 30`
  - Wrong: `$filter=temperature > 30` (use `gt`, `lt`, `ge`, `le`, not `>`, `<`)

- [ ] **Temperature field is marked `filterable`**
  - Index schema → `temperature` field → `"filterable": true`.
  - Non-filterable fields cannot be used in `$filter` expressions.

- [ ] **Data in the index actually has temperature > 30**
  - Run `search=*&$orderby=temperature desc` and inspect the top record.
  - If all records have `temperature <= 30`, generate simulator data with higher values.

---

## Checklist E — Azure AI Foundry rejects the index ("not supported")

- [ ] **AI Search tier is Standard (S1) or higher**
  - Semantic search (required by Foundry Agent) is not available on the Free tier.
  - Check: AI Search resource → Overview → Pricing tier.

- [ ] **Index has a semantic configuration**
  - AI Search → your index → **Semantic configurations** tab — at least one configuration must exist.
  - The configuration must have at least one `contentFields` entry pointing to a `searchable` `Edm.String` field.

- [ ] **`content` field (or equivalent) is searchable and retrievable**
  - Foundry performs full-text + semantic retrieval; purely numeric indexes have no searchable text to rank.
  - Solution: add a `content` field populated with a human-readable string (see [Index Requirements](azure-ai-search-index-requirements.md)).

- [ ] **Key field is `Edm.String` type**
  - Foundry / the underlying API may reject indexes with non-string keys.
  - If your key is an integer, add a string key field and update field mappings.

- [ ] **All fields surfaced to the agent are `retrievable: true`**
  - Non-retrievable fields cannot be included in the agent's context window.

---

## Checklist F — Foundry Agent returns "no data" or wrong answers

- [ ] **Agent is configured to query the correct index**
  - Foundry Agent → Knowledge → verify the data source points to `telemetry-index` (not a different index or project).

- [ ] **Semantic configuration name matches**
  - When connecting the index in Foundry, the semantic configuration dropdown must show and select `telemetry-semantic-config`.

- [ ] **Agent system prompt instructs it to filter by temperature**
  - If the agent's system prompt does not include a clear instruction (e.g., *"Check whether any IoT telemetry records have temperature above 30. If yes, call the alerting tool."*), it may retrieve records but not act on them.

- [ ] **Logic App HTTP endpoint is reachable**
  - Test the Logic App trigger URL directly with a `curl` POST to confirm it returns 200/202.
  - Foundry's HTTP tool call will fail silently if the endpoint returns 4xx/5xx.

- [ ] **Agent is not retrieving a stale document window**
  - If the index contains many historical records and the agent retrieves a fixed number, it may miss the most recent high-temperature events.
  - Solution: add `$orderby=enqueuedTimeUtc desc` to the retrieval configuration, or set `$filter=temperature gt 30` explicitly.

---

## Quick Diagnostic Sequence

```
1. IoT simulator sending?
   └─ IoT Hub → Metrics → D2C messages received (should increment)

2. ASA receiving events?
   └─ ASA job → Monitoring → Input events (should be > 0)

3. Clean blobs written?
   └─ Storage → telemetry-decoded → open a file → confirm JSON lines with numeric temperature

4. Indexer processing blobs?
   └─ AI Search → Indexers → Execution history → Items processed > 0, Items failed = 0

5. Index has documents?
   └─ Search Explorer → search=* (should return documents)

6. Filter works?
   └─ Search Explorer → $filter=temperature gt 30 (should return results if data > 30)

7. Foundry accepts the index?
   └─ Foundry Agent → Knowledge → AI Search → index shows without "not supported" warning

8. Agent answers correctly?
   └─ Agent playground → "Are there high temperature readings?" → agent cites source data
```
