/**
 * Azure Function: telemetry-decoder
 *
 * Trigger : Blob trigger on `telemetry/{name}`
 *           (the container where IoT Hub routes messages in JSON mode)
 *
 * Output  : Blob output to `telemetry-processed/{name}.json`
 *           Contains one clean JSON record per line, ready for Azure AI Search
 *           indexing with parsingMode=jsonLines.
 *
 * Why this function is needed
 * ---------------------------
 * When Azure IoT Hub routes device-to-cloud messages to Blob Storage the file
 * written is a newline-delimited sequence of IoT Hub envelope records, e.g.:
 *
 *   {"EnqueuedTimeUtc":"2026-04-28T10:30:00.000Z",
 *    "Properties":{},
 *    "SystemProperties":{...},
 *    "Body":"eyJtZXNzYWdlSWQiOjEsImRldmljZUlkIjoiUmFzcGJlcnJ5IFBpIFdlYiBDbGllbnQiLCJ0ZW1wZXJhdHVyZSI6MjQuNjI4MjY5NzQ4MTQyNzM1LCJodW1pZGl0eSI6NjEuMjE1MjQ1NjMyNDQzNzc1fQ=="}
 *
 * The `Body` property is Base64-encoded.  Decoded it is:
 *   {"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":24.63,"humidity":61.22}
 *
 * Azure AI Search cannot natively decode Base64.  Unless the Body is decoded,
 * the index never sees temperature/humidity values, so queries like
 *   $filter=temperature gt 30
 * always return zero results and the AI agent incorrectly reports no high readings.
 *
 * This function decodes the Body and writes individual telemetry records so that
 * the search indexer can directly access temperature, humidity, deviceId, etc.
 */

"use strict";

module.exports = async function (context, inputBlob) {
  context.log(
    `telemetry-decoder triggered. Blob: ${context.bindingData.name}, Size: ${inputBlob.length} bytes`
  );

  const rawContent = inputBlob.toString("utf8");

  // IoT Hub writes newline-delimited JSON (one envelope per line).
  // Empty lines (trailing newline) are skipped.
  const lines = rawContent.split("\n").filter((l) => l.trim().length > 0);

  const outputLines = [];

  for (const line of lines) {
    let envelope;
    try {
      envelope = JSON.parse(line);
    } catch (err) {
      context.log.warn(`Skipping non-JSON line: ${line.substring(0, 80)}`);
      continue;
    }

    // The Body field contains the Base64-encoded device message payload.
    if (!envelope.Body) {
      context.log.warn("Envelope missing Body field, skipping.");
      continue;
    }

    let telemetry;
    try {
      const decoded = Buffer.from(envelope.Body, "base64").toString("utf8");
      telemetry = JSON.parse(decoded);
    } catch (err) {
      context.log.warn(
        `Failed to decode/parse Body: ${envelope.Body.substring(0, 80)}`
      );
      continue;
    }

    // Build a flat record that Azure AI Search can index directly.
    // Prefer an explicit timestamp in the payload; fall back to the
    // IoT Hub enqueued time so the field is always populated.
    const record = {
      messageId: telemetry.messageId ?? null,
      deviceId:
        telemetry.deviceId ??
        envelope.SystemProperties?.connectionDeviceId ??
        "unknown",
      temperature:
        typeof telemetry.temperature === "number" ? telemetry.temperature : null,
      humidity:
        typeof telemetry.humidity === "number" ? telemetry.humidity : null,
      timestamp: telemetry.timestamp ?? envelope.EnqueuedTimeUtc ?? null,
      enqueuedTimeUtc: envelope.EnqueuedTimeUtc ?? null,
    };

    // Derive a stable document key from deviceId + messageId so re-indexing
    // the same blob is idempotent (Azure AI Search will update, not duplicate).
    record.id = Buffer.from(
      `${record.deviceId}|${record.messageId}|${record.enqueuedTimeUtc}`
    )
      .toString("base64")
      .replace(/[+/=]/g, "_");

    outputLines.push(JSON.stringify(record));
  }

  if (outputLines.length === 0) {
    context.log("No valid telemetry records found in blob; output skipped.");
    context.bindings.outputBlob = "";
    return;
  }

  context.log(
    `Decoded ${outputLines.length} telemetry record(s) from ${lines.length} envelope(s).`
  );

  // Write newline-delimited JSON so Azure AI Search parsingMode=jsonLines works.
  context.bindings.outputBlob = outputLines.join("\n") + "\n";
};
