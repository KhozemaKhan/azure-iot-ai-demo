# Azure AI Search Index Requirements for Azure AI Foundry Agent

## Overview

When you connect an Azure AI Search index to an **Azure AI Foundry Agent** as a knowledge base, the portal (or SDK) may display:

> *"This index is not supported"*

This document explains **why** that error occurs, **what schema features are required**, and **how to update an existing index** to make it compatible.

---

## Why Azure AI Foundry Rejects an Index

Azure AI Foundry Agent uses **semantic search** and, optionally, **vector search** to retrieve relevant documents from your index. Because of this, an index is rejected when **one or more of the following conditions are not met**:

| Requirement | Why It Is Needed |
|---|---|
| A **semantic configuration** must exist on the index | Foundry uses semantic ranking to score retrieved chunks; without a named semantic configuration the agent cannot issue semantic queries |
| At least one **searchable text field** must be mapped in the semantic configuration's `contentFields` | The agent needs to know which field holds the text it should search and surface to the model |
| A `key` field (Edm.String) must be present | Required by all Azure AI Search indexes; must also be `retrievable` |
| Fields used for retrieval must be `retrievable` | The agent reads field values to construct context; non-retrievable fields are invisible to it |
| (Optional but recommended) A vector field with an `hnsw` or `exhaustiveKnn` algorithm | Enables hybrid search (keyword + vector); improves answer quality |

If any required condition is missing the Foundry UI marks the index as *not supported* and prevents you from saving the connection.

---

## Required Index Schema

### Minimum fields

| Field name | Type | Attributes | Notes |
|---|---|---|---|
| `id` | `Edm.String` | key, retrievable | Document key; generated from `metadata_storage_path` (base64Encode) by the indexer, or from the JSON body |
| `content` | `Edm.String` | searchable, retrievable | **This is the field Foundry reads.** Map the human-readable text you want the agent to reason about here. For IoT telemetry, a concatenated summary string works well (see below). |
| `deviceId` | `Edm.String` | searchable, filterable, retrievable | Device identifier |
| `temperature` | `Edm.Double` | filterable, sortable, retrievable | Sensor reading; must be numeric so filters like `temperature gt 30` work |
| `humidity` | `Edm.Double` | filterable, sortable, retrievable | Sensor reading |
| `messageId` | `Edm.Int64` | filterable, sortable, retrievable | Message sequence number |
| `enqueuedTimeUtc` | `Edm.DateTimeOffset` | filterable, sortable, retrievable | Event timestamp from Stream Analytics / Event Hub |

> **Note on `content` for IoT telemetry:**
> AI Search and Foundry are designed around document text. For numeric telemetry, create a computed string in your indexer or upstream transform, e.g.:
> ```
> "Device Raspberry Pi Web Client reported temperature 31.9°C and humidity 75.7% at 2026-04-28T15:28:49Z"
> ```
> This allows full-text and semantic search to function correctly. The numeric fields remain available for filters.

### Semantic configuration (mandatory for Foundry Agent)

```json
"semantic": {
  "defaultConfiguration": "telemetry-semantic-config",
  "configurations": [
    {
      "name": "telemetry-semantic-config",
      "prioritizedFields": {
        "contentFields": [
          { "fieldName": "content" }
        ],
        "keywordsFields": [
          { "fieldName": "deviceId" }
        ]
      }
    }
  ]
}
```

Key points:
- `contentFields` **must** reference at least one `searchable` `Edm.String` field.
- `name` must match the value you supply when creating the Foundry knowledge base connection (or be the `defaultConfiguration`).
- Semantic configurations require the **Standard** tier or higher on Azure AI Search. The Free tier does **not** support semantic search and therefore cannot be used with Foundry Agent.

### Analyzer

The `content` field should use the standard Lucene analyzer (the default). If your content contains non-English text, set `analyzer` to the appropriate language analyzer. Do not leave the field without an analyzer — Foundry relies on full-text tokenization.

```json
{
  "name": "content",
  "type": "Edm.String",
  "searchable": true,
  "retrievable": true,
  "analyzer": "standard.lucene"
}
```

### Vector field (optional but recommended)

Adding a vector field enables **hybrid search** and significantly improves agent answer quality. Requirements:

- Type: `Collection(Edm.Single)`
- Must have a `vectorSearch` algorithm configuration (`hnsw` recommended)
- `dimensions` must match your embedding model output (e.g. 1536 for `text-embedding-ada-002`, 1024 for `text-embedding-3-small`)

```json
{
  "name": "contentVector",
  "type": "Collection(Edm.Single)",
  "searchable": true,
  "retrievable": false,
  "dimensions": 1536,
  "vectorSearchProfile": "telemetry-vector-profile"
}
```

With accompanying `vectorSearch` section:
```json
"vectorSearch": {
  "algorithms": [
    {
      "name": "telemetry-hnsw",
      "kind": "hnsw",
      "hnswParameters": {
        "metric": "cosine",
        "m": 4,
        "efConstruction": 400,
        "efSearch": 500
      }
    }
  ],
  "profiles": [
    {
      "name": "telemetry-vector-profile",
      "algorithm": "telemetry-hnsw"
    }
  ]
}
```

---

## Field Type Reference

| JSON / ASA type | Azure AI Search type |
|---|---|
| string | `Edm.String` |
| integer / bigint | `Edm.Int32` / `Edm.Int64` |
| float / double | `Edm.Double` |
| boolean | `Edm.Boolean` |
| ISO 8601 timestamp string | `Edm.DateTimeOffset` |
| array of floats (embeddings) | `Collection(Edm.Single)` |

---

## Steps to Make an Existing Index Compatible

Follow these steps if your index already exists but Foundry rejects it.

### Step 1 — Verify the index tier supports semantic search

- Go to **Azure AI Search** resource → **Overview** → note the **Pricing tier**.
- Semantic search requires **Standard (S1)** or higher.
- If you are on Free tier, you must create a new service at Standard tier.

### Step 2 — Add a semantic configuration

1. Azure AI Search → your index → **Semantic configurations** tab.
2. Click **+ Add semantic configuration**.
3. Name it (e.g. `telemetry-semantic-config`).
4. Under **Content fields**, select your `content` field (or whichever field holds the human-readable text).
5. Under **Keyword fields** (optional), select `deviceId`.
6. Save.

Or via REST/ARM, add the `semantic` block shown above to your index definition and issue a `PUT` request to the index endpoint.

### Step 3 — Ensure a `content` field exists and is searchable

If your index only has numeric fields (`temperature`, `humidity`, etc.) and no searchable string, Foundry cannot do full-text or semantic retrieval.

Options:
- **Add a `content` field** to the index schema and populate it via your indexer / Stream Analytics (recommended for new setups).
- **Map `deviceId` as `contentFields`** in the semantic configuration as a temporary measure if you have no other string field.

### Step 4 — Mark required fields as `retrievable`

Check each field the agent needs to read:
- `id` — retrievable (required by key)
- `content` — searchable + retrievable
- `temperature`, `humidity`, `messageId`, `enqueuedTimeUtc` — retrievable (and filterable for filter queries)

Fields that are `retrievable: false` are hidden from the agent response.

### Step 5 — Verify the key field

- Exactly one field must have `"key": true`.
- Type must be `Edm.String`.
- The value must be unique per document.

If your indexer generates the key from `metadata_storage_path`, add a field mapping:
```json
{
  "sourceFieldName": "metadata_storage_path",
  "targetFieldName": "id",
  "mappingFunction": { "name": "base64Encode" }
}
```

### Step 6 — Re-index your data

After any schema change:
1. **Reset** the indexer (Azure AI Search → Indexers → your indexer → Reset).
2. **Run** the indexer.
3. Confirm **Items processed** increases and **Items failed** is 0.

### Step 7 — Reconnect in Azure AI Foundry

1. Azure AI Foundry → your Agent → **Knowledge** → **+ Add data source**.
2. Select **Azure AI Search**.
3. Select your service and index.
4. If the index now has a valid semantic configuration, it will be accepted.
5. Choose the semantic configuration you created, and (optionally) enable hybrid search.

---

## Supported Index JSON Example

See [`examples/search-index-definition.json`](../examples/search-index-definition.json) for a complete, ready-to-use index definition.

---

## Common Mistakes

| Symptom | Likely cause | Fix |
|---|---|---|
| *"This index is not supported"* | No semantic configuration on index | Add semantic config as described in Step 2 |
| Agent returns empty results | `content` field is empty or not mapped correctly | Ensure Stream Analytics or indexer populates `content` with a readable string |
| `temperature` filter returns nothing | Field type is `Edm.String` instead of `Edm.Double` | Recreate the field with correct type and re-index |
| Indexer shows `null` for all JSON fields | Wrong `parsingMode` (e.g., plain text instead of `jsonLines`) | Set `parsingMode` to `json` or `jsonLines` on the indexer |
| `metadata_storage_path` key collision | Multiple blobs with similar paths | Use a field from the JSON itself (e.g. `messageId`) as a stable unique key |
