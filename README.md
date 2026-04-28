# Azure IoT + AI Agent Temperature Monitoring Demo

A proof-of-concept that connects a Raspberry Pi Web Simulator to Azure IoT Hub, indexes telemetry data with Azure AI Search, and uses an Azure AI Foundry Agent to automatically trigger Logic App email alerts when temperature exceeds 30 °C.

## Solution Architecture

```
Raspberry Pi Web Simulator
        │  telemetry JSON
        ▼
  Azure IoT Hub
        │  message routing
        ▼
  Azure Blob Storage
        │  blob trigger / schedule
        ▼
  Azure AI Search (Indexer)
        │  grounded knowledge base
        ▼
  Azure AI Foundry Agent  ──── OpenAI Function Call ────►  Azure Logic App
                                                                  │
                                                                  ▼
                                                            Email Alert
```

## Simulator Payload

The Raspberry Pi Web Simulator sends messages in this exact format:

```json
{
  "messageId": 1,
  "deviceId": "Raspberry Pi Web Client",
  "temperature": 24.63,
  "humidity": 61.22
}
```

Azure IoT Hub appends `enqueuedTime` when routing to Storage, so the full document stored in Blob (and indexed by AI Search) includes:

| Field | Type | Source |
|-------|------|--------|
| `messageId` | integer | Device simulator |
| `deviceId` | string | Device simulator |
| `temperature` | number (°C) | Device simulator |
| `humidity` | number (%) | Device simulator |
| `enqueuedTime` | ISO-8601 string | IoT Hub (appended on routing) |

## Repository Structure

```
├── README.md
└── docs/
    ├── setup-guide.md            # End-to-end step-by-step setup
    ├── openapi-logicapp.yaml     # OpenAPI 3.0.3 schema for Logic App action
    └── agent-tool-configuration.md  # Configuring AI Agent tool with Logic App URL
```

## Quick Start

1. Follow [docs/setup-guide.md](docs/setup-guide.md) to deploy all Azure resources.
2. Use [docs/openapi-logicapp.yaml](docs/openapi-logicapp.yaml) as the OpenAPI schema when adding the Logic App as an agent action/tool.
3. See [docs/agent-tool-configuration.md](docs/agent-tool-configuration.md) for detailed guidance on configuring the agent action URL (including the `sig` query parameter).

## Estimated Daily Cost (Active Testing)

| Resource | ~Cost/day |
|----------|-----------|
| IoT Hub S1 | $0.83 |
| Storage LRS | $0.01 |
| AI Search Basic | $2.50 |
| Logic App (Consumption) | $0.01 |
| AI Foundry / GPT-4 | $0.10–$1.00 |
| **Total** | **~$3–5** |

> **Tip:** Delete the resource group when not testing to avoid idle charges.
>
> ```bash
> az group delete --name iot-ai-demo-rg --yes --no-wait
> ```
