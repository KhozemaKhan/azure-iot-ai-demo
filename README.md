# azure-iot-ai-demo
Azure IoT + AI Agent Temperature Monitoring POC

## Overview

End-to-end demo that:

1. Reads temperature/humidity messages sent by the **Raspberry Pi Web Simulator** to **Azure IoT Hub**
2. Routes raw messages (blob-format) to Azure Storage (`telemetry-raw`)
3. Decodes the IoT Hub envelope with an **Azure Function** (`telemetry-decoder`) and writes clean JSON to `telemetry-decoded`
4. Indexes the clean JSON with **Azure AI Search** so `messageId`, `deviceId`, `temperature`, and `humidity` are all populated and filterable
5. An **AI Foundry Agent** queries the index and calls a **Logic App** webhook when temperature exceeds 30 °C — triggering an email alert

## Repository Layout

```
├── functions/
│   └── telemetry-decoder/       # Azure Function (Node.js v4, blob trigger)
│       ├── src/functions/
│       │   └── telemetryDecoder.js
│       ├── host.json
│       ├── package.json
│       └── local.settings.json.example
├── infra/
│   ├── main.bicep               # Provisions Storage, Function App, IoT Hub, AI Search
│   └── main.parameters.json
├── search/
│   ├── index-schema.json        # AI Search index (messageId/deviceId/temperature/humidity)
│   ├── datasource-config.json   # Points at telemetry-decoded container
│   └── indexer-config.json      # parsingMode: jsonLines
├── scripts/
│   ├── setup.sh                 # Full one-command deployment
│   ├── deploy-function.sh       # Publish Function App only
│   └── test-decode-local.js     # Local unit test for the decode pipeline
└── docs/
    └── deployment-guide.md      # Step-by-step guide + troubleshooting
```

## Why `telemetry-raw` → `telemetry-decoded`?

IoT Hub wraps every device message in an envelope with a base64-encoded `Body`:

```json
{
  "EnqueuedTimeUtc": "2026-04-28T10:30:00.000Z",
  "Body": "eyJtZXNzYWdlSWQiOjEsImRldmljZUlkIjoiUmFzcGJlcnJ5IFBpIFdlYiBDbGllbnQiLCJ0ZW1wZXJhdHVyZSI6MjQuNjIsImh1bWlkaXR5Ijo2MS4yfQ=="
}
```

Azure AI Search cannot automatically base64-decode `Body`, so indexing the raw
container leaves `messageId`, `deviceId`, `temperature`, and `humidity` all null.

The `telemetry-decoder` Function decodes each envelope and writes flat JSON lines:

```json
{"id":"...","messageId":"1","deviceId":"Raspberry Pi Web Client","temperature":24.62,"humidity":61.2,"enqueuedTimeUtc":"2026-04-28T10:30:00.000Z"}
```

## Quick Start

```bash
# 1. Log in
az login

# 2. Deploy everything
chmod +x scripts/setup.sh
./scripts/setup.sh iot-ai-demo-rg eastus

# 3. Test the decode logic locally
node scripts/test-decode-local.js
```

See **[docs/deployment-guide.md](docs/deployment-guide.md)** for the full
step-by-step guide, AI Agent configuration, sample queries, and troubleshooting.

## Sample Queries (after indexer runs)

```bash
# All documents
curl "https://<SEARCH>.search.windows.net/indexes/iot-telemetry-index/docs?api-version=2023-11-01&search=*" \
  -H "api-key: <ADMIN_KEY>"

# Temperature > 30 °C (used by AI Agent to trigger Logic App)
curl "https://<SEARCH>.search.windows.net/indexes/iot-telemetry-index/docs?api-version=2023-11-01&\$filter=temperature gt 30&\$orderby=enqueuedTimeUtc desc" \
  -H "api-key: <ADMIN_KEY>"
```

## Estimated Cost (1 day of active testing)

| Resource | ~Daily cost |
|----------|------------|
| IoT Hub S1 | $0.83 |
| Storage (LRS) | $0.01 |
| Function App (consumption) | <$0.01 |
| AI Search Basic | $2.50 |
| Logic App consumption | $0.01 |
| AI Foundry (GPT-4) | $0.10–$1.00 |

**Tip:** Run `az group delete --name iot-ai-demo-rg --yes` when done to stop all costs.
