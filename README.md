# azure-iot-ai-demo
Azure IoT + AI Agent Temperature Monitoring POC

## Overview

This repository contains a proof-of-concept (POC) for an end-to-end IoT telemetry pipeline that streams real-time sensor data (temperature, humidity) from IoT devices through Azure services into an AI-powered monitoring agent.

### Pipeline

```
IoT Device → IoT Hub → Stream Analytics → Blob Storage (telemetry-decoded)
  → Azure AI Search Index → Azure AI Foundry Agent (Knowledge Base) → Logic App Alert
```

## Documentation

For full architecture, step-by-step setup instructions, troubleshooting, and best practices, see the **[complete wiki](docs/wiki.md)**.

### Quick links

- [Architecture Diagram](docs/wiki.md#architecture-diagram--flow)
- [Stream Analytics Query](docs/wiki.md#34-stream-analytics-query)
- [Search Index Schema](docs/wiki.md#52-index-schema)
- [Indexer Configuration](docs/wiki.md#step-6--search-indexer-jsonlines--id-mapping)
- [Agent Instructions](docs/wiki.md#74-agent-instructions-updated)
- [Troubleshooting & FAQ](docs/wiki.md#troubleshooting--faq)
- [Best Practices & Lessons Learned](docs/wiki.md#best-practices--lessons-learned)
