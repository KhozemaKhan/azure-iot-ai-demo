# azure-iot-ai-demo

Azure IoT + AI Agent Temperature Monitoring POC

## Overview

This repository implements an end-to-end pipeline that:

1. Receives JSON telemetry from a Raspberry Pi simulator via **Azure IoT Hub**
2. Decodes and routes the data through **Azure Stream Analytics** (bypassing the IoT Hub blob Base64-envelope issue)
3. Writes clean, newline-delimited JSON to a Blob Storage container (`telemetry-decoded`)
4. Indexes the data with **Azure AI Search** so an AI agent can query for high-temperature readings
5. Triggers an **Azure Logic App** alert when temperature exceeds 30°C

## Architecture

```
IoT Simulator → IoT Hub → Azure Stream Analytics → Blob (telemetry-decoded) → AI Search → Foundry Agent → Logic App
```

## Repository Structure

```
infra/
  main.bicep              # Main Bicep template (ASA job + consumer group + container)
  main.bicepparam         # Example parameter file
  modules/
    stream-analytics.bicep  # Stream Analytics job module

search/
  index.json              # AI Search index schema
  datasource.json         # AI Search datasource (points to telemetry-decoded)
  indexer.json            # AI Search indexer (parsingMode: jsonLines)

scripts/
  deploy-asa.sh           # Deploy infrastructure via Bicep
  start-asa.sh            # Start the Stream Analytics job
  setup-search.sh         # Create/update index, datasource, and indexer
  validate-search.sh      # Query AI Search to verify temperature data

docs/
  stream-analytics-guide.md  # Full step-by-step guide + troubleshooting
```

## Quick Start

```bash
# 1. Deploy infrastructure
./scripts/deploy-asa.sh \
    --resource-group  my-iot-rg \
    --iot-hub         my-iot-hub \
    --storage-account mystorageaccount

# 2. Start the Stream Analytics job
./scripts/start-asa.sh \
    --resource-group  my-iot-rg

# 3. Configure AI Search
./scripts/setup-search.sh \
    --search-service   my-search-service \
    --admin-api-key    <ADMIN_KEY> \
    --storage-conn-str "<STORAGE_CONNECTION_STRING>"

# 4. Validate
./scripts/validate-search.sh \
    --search-service my-search-service \
    --api-key        <QUERY_KEY>
```

## Full Guide

See [docs/stream-analytics-guide.md](docs/stream-analytics-guide.md) for:

- Detailed architecture explanation
- Why direct Event Hub → AI Search is not supported
- Portal and CLI setup steps
- AI Search configuration details
- Foundry agent prompt guidance
- Troubleshooting checklist
- Sample queries (`$filter=temperature gt 30`)
