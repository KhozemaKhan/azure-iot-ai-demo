# azure-iot-ai-demo
Azure IoT + AI Agent Temperature Monitoring POC

## Overview

This repository contains documentation and resources for a proof-of-concept that monitors IoT device telemetry, detects temperature anomalies with an AI agent, and sends alerts via a Logic App.

## Pipeline

```
IoT Simulator → IoT Hub → Stream Analytics → Blob (telemetry-decoded)
   → Azure AI Search indexer → Azure AI Foundry agent → Logic App alerts
```

## Documentation

| Guide | Description |
|---|---|
| [Stream Analytics Pipeline](docs/stream-analytics-pipeline.md) | Step-by-step guide for the full pipeline: IoT Hub → Stream Analytics → Blob → AI Search → Foundry agent → Logic App alerts. Includes portal and CLI steps, all required configurations, validation steps, and troubleshooting. |
