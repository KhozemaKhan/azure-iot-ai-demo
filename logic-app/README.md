# Logic App – HTTP Trigger Configuration

This Logic App receives temperature/humidity telemetry from the AI Foundry Agent (via its generic HTTP tool) and sends an email alert when the temperature exceeds the configured threshold.

---

## 1. Create the Logic App

1. In the [Azure Portal](https://portal.azure.com), click **Create a resource** → search for **Logic App**.
2. Fill in the basics:
   | Field | Value |
   |---|---|
   | Resource Group | `iot-ai-demo-rg` |
   | Name | `temperature-alert-logic-app` |
   | Region | `East US` |
   | Plan type | `Consumption` |
3. Click **Review + Create** → **Create**.

---

## 2. Add the HTTP Request Trigger

1. Open the new Logic App → **Logic app designer**.
2. Choose **When a HTTP request is received** as the first step.
3. Paste the following JSON schema into the **Request Body JSON Schema** box.

### Request Body JSON Schema

This schema matches the payload that the AI Foundry Agent sends, which mirrors the simulator message format:

```json
{
  "type": "object",
  "properties": {
    "messageId": {
      "type": "integer",
      "description": "Sequential message counter from the device"
    },
    "deviceId": {
      "type": "string",
      "description": "Identifier of the IoT device (e.g. 'Raspberry Pi Web Client')"
    },
    "temperature": {
      "type": "number",
      "description": "Temperature reading in degrees Celsius"
    },
    "humidity": {
      "type": "number",
      "description": "Relative humidity as a percentage"
    },
    "enqueuedTime": {
      "type": "string",
      "description": "ISO-8601 timestamp when the message was enqueued (optional – may be absent from simulator)"
    }
  },
  "required": ["messageId", "deviceId", "temperature", "humidity"]
}
```

> **Note:** `enqueuedTime` is optional. The Raspberry Pi Web Simulator sends only `messageId`, `deviceId`, `temperature`, and `humidity`.

4. Click **Save**. The designer will generate the **HTTP POST URL** – **copy and keep it**; you will use it in the Agent configuration.

### Example callback URL

```
https://prod-XX.eastus.logic.azure.com:443/workflows/<workflowId>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<signatureValue>
```

> The `sig` query-parameter is a shared-access signature that authenticates the caller. **Always use the full URL including `sig`** – do not strip the query-string or the request will be rejected with HTTP 403.

---

## 3. Add a Condition (Temperature Threshold)

1. Click **+ New step** → search **Condition**.
2. Configure the condition:
   - **Left side:** `temperature` (dynamic content from the HTTP trigger body)
   - **Operator:** `is greater than`
   - **Right side:** `30`

---

## 4. Add an Email Action (True branch)

1. Inside the **True** branch click **Add an action** → search **Send an email (V2)** (Office 365 Outlook or Gmail).
2. Sign in and configure:
   | Field | Value |
   |---|---|
   | To | your-email@example.com |
   | Subject | `🚨 Temperature Alert – @{triggerBody()?['deviceId']}` |
   | Body | See template below |

**Email body template:**
```
⚠️ Temperature Alert Detected!

Message ID  : @{triggerBody()?['messageId']}
Device ID   : @{triggerBody()?['deviceId']}
Temperature : @{triggerBody()?['temperature']} °C
Humidity    : @{triggerBody()?['humidity']} %
Time        : @{coalesce(triggerBody()?['enqueuedTime'], utcNow())}
```

3. **Save** the Logic App.

---

## 5. Test the Logic App Independently

Before wiring up the Agent, validate the Logic App with a `curl` command using the full callback URL:

```bash
curl -X POST \
  "https://prod-XX.eastus.logic.azure.com:443/workflows/<workflowId>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<signatureValue>" \
  -H "Content-Type: application/json" \
  -d '{
    "messageId": 1,
    "deviceId": "Raspberry Pi Web Client",
    "temperature": 35.5,
    "humidity": 61.2
  }'
```

Expected HTTP response: **`202 Accepted`**

You should receive a test email within a few seconds if the temperature is above 30 °C.

---

## 6. Copy the Callback URL

After saving, the **HTTP POST URL** is visible in the trigger step. It looks like:

```
https://prod-XX.eastus.logic.azure.com:443/workflows/<workflowId>/triggers/manual/paths/invoke
  ?api-version=2016-10-01
  &sp=%2Ftriggers%2Fmanual%2Frun
  &sv=1.0
  &sig=<signatureValue>
```

Copy the **entire URL** (including all query parameters). This is what you will paste into the Agent's HTTP tool configuration.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| HTTP 403 | `sig` parameter missing or wrong | Use the full callback URL copied from the trigger |
| HTTP 400 | Malformed JSON body | Verify `Content-Type: application/json` header is set |
| No email received | Condition not met | Check the temperature value exceeds 30 °C |
| Runs history shows "Failed" | Schema validation error | Ensure `messageId` is an integer, `temperature` is a number |
