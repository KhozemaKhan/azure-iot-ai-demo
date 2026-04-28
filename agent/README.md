# Azure AI Foundry Agent – Configuration Guide

This guide explains how to configure an Azure AI Foundry Agent that uses a **generic HTTP tool** to call the Logic App HTTP trigger and send temperature alerts.

---

## Prerequisites

- An Azure AI Foundry project with a deployed GPT-4 (or GPT-4o) model.
- The Logic App callback URL (with `sig`) from [logic-app/README.md](../logic-app/README.md).
- An Azure AI Search index populated with IoT telemetry (see root [README.md](../README.md)).

---

## 1. Create the Agent

1. Go to [ai.azure.com](https://ai.azure.com) → open your project.
2. Navigate to **Agents** → **+ Create agent**.
3. Give the agent a name, e.g. `iot-temperature-monitor`.
4. Select your deployed model (e.g. `gpt-4o-deployment`).

---

## 2. System Prompt

Paste the following into the **System message** / **Instructions** box:

```
You are an IoT temperature monitoring agent connected to an Azure AI Search knowledge base that contains real-time telemetry from IoT devices.

Your responsibilities:
1. When asked, query the Azure AI Search index for the latest temperature and humidity readings.
2. Identify any device whose temperature exceeds 30 °C.
3. For every device in violation, call the trigger_temperature_alert HTTP tool with:
   - messageId   – the integer message counter from the telemetry record
   - deviceId    – the string device identifier (e.g. "Raspberry Pi Web Client")
   - temperature – the numeric temperature value in Celsius
   - humidity    – the numeric humidity percentage
   - enqueuedTime (optional) – ISO-8601 timestamp if available in the record
4. Report back a summary of which devices were alerted.

Always prefer factual data from the search index over assumptions.
```

---

## 3. Connect Azure AI Search (Knowledge Base)

1. In the agent configuration panel, find **Knowledge** or **Data sources**.
2. Click **+ Add** → select **Azure AI Search**.
3. Fill in:
   | Field | Value |
   |---|---|
   | Search service endpoint | `https://my-ai-search-demo.search.windows.net` |
   | Index name | `iot-telemetry-index` |
   | Authentication | API key (paste your admin key) |
4. Click **Add**.

---

## 4. Add the Generic HTTP Tool

> **Important:** Use the **generic HTTP tool** (also called the *HTTP action* or *HTTP request tool*) built into Azure AI Foundry Agents. Do **not** wrap it in an OpenAPI tool definition – OpenAPI tool definitions introduce the fields `HTTP_URI` and `HTTP_request_content`, which are **not** used by the generic HTTP tool and will cause the configuration to fail silently.

### 4.1 Add the tool

1. In the agent configuration, scroll to **Tools** → **+ Add tool**.
2. Select **HTTP** (generic HTTP request action).

### 4.2 Tool settings

| Setting | Value |
|---|---|
| Tool name | `trigger_temperature_alert` |
| Description | `Sends a temperature alert to the Logic App when a device exceeds the threshold.` |
| Method | `POST` |
| URL | *(see Section 4.3 below)* |

### 4.3 Logic App callback URL – full URL vs base URL

The Logic App HTTP trigger generates a URL with embedded authentication:

```
https://prod-XX.eastus.logic.azure.com:443/workflows/<workflowId>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<signatureValue>
```

**Always paste the full URL including all query parameters** (especially `sig`) into the **URL** field of the generic HTTP tool.

| Approach | URL field | Result |
|---|---|---|
| ✅ Full callback URL | `https://prod-XX…?api-version=…&sig=<value>` | Logic App authenticates and executes |
| ❌ Base URL only | `https://prod-XX…/invoke` | HTTP 403 Forbidden – `sig` is missing |
| ❌ Split base + params | Base URL in field, params elsewhere | Not supported by generic HTTP tool |

### 4.4 Headers

Add the following request header:

| Header name | Header value |
|---|---|
| `Content-Type` | `application/json` |

> Without `Content-Type: application/json`, the Logic App will not parse the JSON body and the run will fail with HTTP 400.

### 4.5 Body template

The body must match the simulator payload schema. Use this JSON template (the agent fills in values from the telemetry record it retrieved from AI Search):

```json
{
  "messageId": {{messageId}},
  "deviceId": "{{deviceId}}",
  "temperature": {{temperature}},
  "humidity": {{humidity}},
  "enqueuedTime": "{{enqueuedTime}}"
}
```

**Field reference:**

| Field | Type | Required | Description |
|---|---|---|---|
| `messageId` | integer | Yes | Sequential message counter (e.g. `1`, `2`, `3`) |
| `deviceId` | string | Yes | Device identifier string (e.g. `"Raspberry Pi Web Client"`) |
| `temperature` | number | Yes | Temperature in °C (e.g. `35.47`) |
| `humidity` | number | Yes | Relative humidity % (e.g. `61.2`) |
| `enqueuedTime` | string | No | ISO-8601 timestamp; omit or leave blank if not available |

> **Schema note:** This matches the message format produced by the Raspberry Pi Web Simulator:
> ```json
> {"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":24.628269748142735,"humidity":61.215245632443775}
> ```

### 4.6 Function definition (for SDK / API use)

If you are configuring the agent via the Azure AI Foundry SDK or REST API instead of the portal, use this function schema:

```json
{
  "name": "trigger_temperature_alert",
  "description": "Sends a temperature alert to the Logic App HTTP trigger when a device temperature exceeds the threshold.",
  "parameters": {
    "type": "object",
    "properties": {
      "messageId": {
        "type": "integer",
        "description": "Sequential message ID from the IoT telemetry record."
      },
      "deviceId": {
        "type": "string",
        "description": "Device identifier string, e.g. 'Raspberry Pi Web Client'."
      },
      "temperature": {
        "type": "number",
        "description": "Temperature reading in degrees Celsius."
      },
      "humidity": {
        "type": "number",
        "description": "Relative humidity as a percentage."
      },
      "enqueuedTime": {
        "type": "string",
        "description": "ISO-8601 timestamp when the message was enqueued. Optional – may be absent from simulator payloads."
      }
    },
    "required": ["messageId", "deviceId", "temperature", "humidity"]
  }
}
```

---

## 5. Save and Test the Agent

### 5.1 Quick playground test

In the **Agent playground** (chat window), send:

```
Check the latest temperature readings and trigger an alert for any device above 30 °C.
```

Expected behaviour:
1. The agent queries the AI Search index.
2. If any record shows `temperature > 30`, it calls `trigger_temperature_alert`.
3. The Logic App receives the POST, evaluates the condition, and sends an alert email.
4. The agent reports back which devices were alerted.

### 5.2 Test the HTTP tool directly with curl

Before or after configuring the agent, you can test the entire call chain independently:

```bash
curl -X POST \
  "https://prod-XX.eastus.logic.azure.com:443/workflows/<workflowId>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<signatureValue>" \
  -H "Content-Type: application/json" \
  -d '{
    "messageId": 42,
    "deviceId": "Raspberry Pi Web Client",
    "temperature": 36.8,
    "humidity": 58.4
  }'
```

Expected HTTP response: **`202 Accepted`**

---

## 6. Common Mistakes and Fixes

| Mistake | Symptom | Fix |
|---|---|---|
| Using OpenAPI tool instead of generic HTTP tool | `HTTP_URI` / `HTTP_request_content` fields appear; tool call ignored | Switch to **generic HTTP tool** (not OpenAPI wrapper) |
| Pasting only the base URL without `sig` | HTTP 403 from Logic App | Paste the **full callback URL** including all query params |
| Missing `Content-Type` header | HTTP 400; Logic App body is empty | Add `Content-Type: application/json` header |
| `messageId` sent as string | Schema validation warning | Ensure `messageId` is an **integer** (no quotes) |
| `enqueuedTime` hardcoded as empty string | Logic App expression errors | Make `enqueuedTime` optional in body; omit the field if not available |

---

## 7. Azure AI Search Index Schema

For reference, here is the recommended index schema that matches the simulator payload:

```json
{
  "name": "iot-telemetry-index",
  "fields": [
    { "name": "id",           "type": "Edm.String",        "key": true,  "searchable": false },
    { "name": "messageId",    "type": "Edm.Int32",          "key": false, "searchable": false, "filterable": true, "sortable": true },
    { "name": "deviceId",     "type": "Edm.String",         "key": false, "searchable": true,  "filterable": true },
    { "name": "temperature",  "type": "Edm.Double",         "key": false, "filterable": true,  "sortable": true },
    { "name": "humidity",     "type": "Edm.Double",         "key": false, "filterable": true,  "sortable": true },
    { "name": "enqueuedTime", "type": "Edm.DateTimeOffset", "key": false, "filterable": true,  "sortable": true }
  ]
}
```

> `enqueuedTime` is added by IoT Hub message routing; it is **not** present in the raw simulator payload but is available in blobs stored via IoT Hub → Storage routing.
