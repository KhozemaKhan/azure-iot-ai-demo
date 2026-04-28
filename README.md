# azure-iot-ai-demo

Azure IoT + AI Agent Temperature Monitoring POC

This repository demonstrates an end-to-end IoT telemetry pipeline that feeds an **Azure AI Foundry Agent** with real-time sensor data so it can detect anomalies (e.g. temperature > 30 °C) and trigger automated actions via **Azure Logic Apps**.

---

## Architecture

```
IoT Simulator
     │
     ▼
Azure IoT Hub
     │  (built-in Event Hub–compatible endpoint)
     ▼
Azure Stream Analytics
     │  (parses + projects telemetry fields, writes clean JSON)
     ▼
Blob Storage – container: telemetry-decoded
     │  (newline-delimited JSON, one record per line)
     ▼
Azure AI Search Indexer
     │  (parsingMode: jsonLines)
     ▼
Azure AI Search Index
     │  (semantic configuration required for Foundry Agent)
     ▼
Azure AI Foundry Agent  ──► Azure Logic App (alert / action)
```

---

## Documentation

| Document | Description |
|---|---|
| [Azure AI Search Index Requirements](docs/azure-ai-search-index-requirements.md) | Why Azure AI Foundry rejects an index as *not supported*, required schema fields, and how to make an existing index compatible |
| [Stream Analytics Pipeline Guide](docs/stream-analytics-pipeline.md) | Step-by-step setup for the IoT Hub → Stream Analytics → Blob → AI Search → Foundry pipeline |
| [Troubleshooting Checklist](docs/troubleshooting.md) | Common failure modes and how to diagnose/fix them |

## Examples

| File | Description |
|---|---|
| [examples/search-index-definition.json](examples/search-index-definition.json) | Complete Azure AI Search index JSON compatible with Azure AI Foundry Agent |
| [examples/stream-analytics-query.sql](examples/stream-analytics-query.sql) | Stream Analytics query that projects clean telemetry fields from IoT Hub events |

---

## Quick Start

1. [Set up the Stream Analytics pipeline](docs/stream-analytics-pipeline.md)
2. [Verify your AI Search index schema](docs/azure-ai-search-index-requirements.md)
3. Connect the index to your Azure AI Foundry Agent knowledge base
4. If anything goes wrong, consult the [Troubleshooting Checklist](docs/troubleshooting.md)
