# Configuring the AI Agent Tool for the Logic App Action

This document explains how to register the Azure Logic App as an **action tool** in your Azure AI Foundry Agent, including how to handle the Logic App URL and its required `sig` (Shared Access Signature) query-string parameter.

---

## 1. Obtain the Logic App Trigger URL

After saving the Logic App workflow (see [setup-guide.md Step 14](setup-guide.md#step-14--configure-the-logic-app-workflow)):

1. Open the Logic App in the Azure Portal.
2. In the designer, click the **"When a HTTP request is received"** trigger to expand it.
3. Copy the **HTTP POST URL** — it looks like this:

   ```
   https://prod-xx.eastus.logic.azure.com:443/workflows/<workflowId>/triggers/manual/paths/invoke
     ?api-version=2016-10-01
     &sp=%2Ftriggers%2Fmanual%2Frun
     &sv=1.0
     &sig=<YOUR_SIG_VALUE>
   ```

The query-string parameters are:

| Parameter | Meaning |
|-----------|---------|
| `api-version` | Logic Apps REST API version (`2016-10-01`) |
| `sp` | URL-encoded scope/permission (`/triggers/manual/run`) |
| `sv` | SAS token version (`1.0`) |
| `sig` | **Shared Access Signature** — authenticates every request; treat this like a secret |

> **Security note:** The `sig` value is a secret. Do not commit it to source control. Store it in Azure Key Vault or as a secure environment variable / agent secret.

---

## 2. Register the Action Tool in Azure AI Foundry

Azure AI Foundry Agents support **OpenAPI-based action tools**. Use the schema in [openapi-logicapp.yaml](openapi-logicapp.yaml) as your tool definition.

### 2a. Using the OpenAPI Schema (Recommended)

1. In AI Foundry → your agent → **Tools** → **+ Add tool** → **OpenAPI**.
2. Upload or paste the contents of `docs/openapi-logicapp.yaml`.
3. When prompted for the **Server URL**, replace the placeholder with your full Logic App trigger URL, **including all query parameters**:

   ```
   https://prod-xx.eastus.logic.azure.com:443/workflows/<workflowId>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<YOUR_SIG>
   ```

4. Set **Authentication** to **None** (the `sig` parameter already authenticates the request).

> **Tip:** Some portal versions allow you to store the URL in a connection or secret. Prefer that over embedding the raw `sig` in the YAML file.

---

### 2b. Using a Function Calling Definition (Alternative)

If you prefer classic function calling instead of an OpenAPI tool, add the following function definition to the agent:

```json
{
  "name": "trigger_temperature_alert",
  "description": "Sends a temperature alert by invoking the Logic App HTTP webhook. Call this whenever a device reports temperature above 30 °C.",
  "parameters": {
    "type": "object",
    "properties": {
      "messageId": {
        "type": "integer",
        "description": "Sequential message counter from the Raspberry Pi Web Simulator (maps to 'messageId' in the simulator payload)."
      },
      "deviceId": {
        "type": "string",
        "description": "Device identifier sent by the simulator (maps to 'deviceId' in the simulator payload). Default: 'Raspberry Pi Web Client'."
      },
      "temperature": {
        "type": "number",
        "description": "Temperature in Celsius from the simulator (maps to 'temperature' in the simulator payload)."
      },
      "humidity": {
        "type": "number",
        "description": "Relative humidity percentage from the simulator (maps to 'humidity' in the simulator payload)."
      },
      "enqueuedTime": {
        "type": "string",
        "description": "ISO-8601 UTC timestamp appended by IoT Hub when routing the message to Blob Storage (maps to 'enqueuedTime' in the indexed document)."
      }
    },
    "required": ["deviceId", "temperature", "enqueuedTime"]
  }
}
```

Configure the HTTP action:

| Setting | Value |
|---------|-------|
| **Method** | `POST` |
| **URL** | Full Logic App trigger URL including `?api-version=…&sig=…` |
| **Headers** | `Content-Type: application/json` |
| **Body** | JSON object with all five fields from the function call arguments |

---

## 3. Payload Mapping: Simulator → Index → Alert

The following diagram shows how data flows from the simulator through to the alert payload:

```
Raspberry Pi Web Simulator
  sends JSON:
    { "messageId": 1,
      "deviceId": "Raspberry Pi Web Client",
      "temperature": 35.5,
      "humidity": 60.1 }
           │
           ▼
  Azure IoT Hub (message routing)
    appends: "enqueuedTime": "2026-04-28T10:30:00.000Z"
           │
           ▼
  Azure Blob Storage
    stores full document:
    { "messageId": 1,
      "deviceId": "Raspberry Pi Web Client",
      "temperature": 35.5,
      "humidity": 60.1,
      "enqueuedTime": "2026-04-28T10:30:00.000Z" }
           │
           ▼
  Azure AI Search (indexer reads blob, 5-min schedule)
    indexes document with fields:
      messageId, deviceId, temperature, humidity, enqueuedTime
           │
           ▼
  Azure AI Foundry Agent
    queries index, finds temperature > 30 °C
    calls trigger_temperature_alert(
      messageId=1,
      deviceId="Raspberry Pi Web Client",
      temperature=35.5,
      humidity=60.1,
      enqueuedTime="2026-04-28T10:30:00.000Z"
    )
           │
           ▼
  Logic App HTTP Trigger
    POST https://…logic.azure.com/…?sig=<YOUR_SIG>
    Body: { "messageId":1, "deviceId":"Raspberry Pi Web Client",
            "temperature":35.5, "humidity":60.1,
            "enqueuedTime":"2026-04-28T10:30:00.000Z" }
           │
           ▼
  Office 365 / Outlook — Email Alert sent
```

---

## 4. Handling the `sig` Parameter Securely

The `sig` value expires only when you manually regenerate it in the Logic App. Still, treat it as a secret:

1. **Store in Azure Key Vault:**
   - Create a secret named `logicapp-sig`.
   - Reference it from your agent or the code that invokes the agent.

2. **Store as an AI Foundry Agent connection:**
   - In AI Foundry → **Settings → Connections → + New connection → Custom**.
   - Store the full URL (with `sig`) as the connection endpoint.
   - Reference the connection in the tool configuration instead of hardcoding the URL.

3. **Rotate when compromised:**
   - Open the Logic App → trigger designer → **Regenerate key**.
   - Update the stored secret / connection immediately.

---

## 5. Quick Test

After configuring the tool, test the full round-trip:

```bash
# Direct curl test of the Logic App (validates URL + sig are correct)
curl -X POST \
  "https://prod-xx.eastus.logic.azure.com:443/workflows/<id>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<YOUR_SIG>" \
  -H "Content-Type: application/json" \
  -d '{
    "messageId": 99,
    "deviceId": "Raspberry Pi Web Client",
    "temperature": 36.0,
    "humidity": 55.0,
    "enqueuedTime": "2026-04-28T12:00:00.000Z"
  }'
```

Expected: HTTP 200 or 202 response, and an email arrives in your inbox.

Then test through the agent playground:

```
Check the most recent telemetry from the IoT index.
If any device is above 30 °C, send a temperature alert now.
```

---

## 6. Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| HTTP 401 from Logic App | `sig` is wrong or missing | Re-copy the full URL from the Logic App designer |
| HTTP 400 from Logic App | Request body doesn't match schema | Verify all five fields are present and correctly typed |
| Agent doesn't call the tool | Tool definition not saved | Re-open agent settings → Tools and confirm the action is listed |
| Agent passes wrong field names | System prompt unclear | Add explicit field mapping to the system prompt (see setup-guide.md Step 18) |
| `sig` expired / revoked | Key was regenerated | Update the stored URL/secret with the new `sig` value |
