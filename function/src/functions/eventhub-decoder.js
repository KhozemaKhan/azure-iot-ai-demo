'use strict';

/**
 * EventHubDecoder
 *
 * Triggered by the IoT Hub built-in Event Hub-compatible endpoint.
 * Each invocation receives a batch of device messages whose body is plain JSON
 * (unlike IoT Hub → Blob Storage routing, where the body is Base64-encoded).
 *
 * For each message the function produces a clean JSON document:
 *   { id, messageId, deviceId, temperature, humidity, enqueuedTimeUtc }
 *
 * All documents in the batch are written as newline-delimited JSON (JSON Lines)
 * into a single blob in the "telemetry-decoded" container so that the
 * Azure AI Search blob indexer (parsingMode: jsonLines) can index them.
 */

const { app, output } = require('@azure/functions');
const { BlobServiceClient } = require('@azure/storage-blob');

// ── Blob output binding ───────────────────────────────────────────────────────
// Each invocation writes one blob. {rand-guid} ensures a unique blob name.
const blobOutput = output.storageBlob({
  path: 'telemetry-decoded/{rand-guid}.json',
  connection: 'AzureWebJobsStorage',
});

// ── Main function registration ────────────────────────────────────────────────
app.eventHub('EventHubDecoder', {
  connection: 'IoTHubConnection',
  eventHubName: '%IoTHubEventHubName%',
  consumerGroup: '%IoTHubConsumerGroup%',
  cardinality: 'many',
  extraOutputs: [blobOutput],

  handler: async (events, context) => {
    if (!Array.isArray(events) || events.length === 0) {
      context.log('EventHubDecoder: no events in this invocation, skipping.');
      return;
    }

    context.log(`EventHubDecoder: processing batch of ${events.length} event(s).`);

    // Binding metadata arrays (one entry per event in the batch)
    const enqueuedTimeArray =
      context.triggerMetadata?.enqueuedTimeUtcArray ?? [];
    const systemPropsArray =
      context.triggerMetadata?.systemPropertiesArray ?? [];

    const lines = [];

    for (let i = 0; i < events.length; i++) {
      try {
        // The IoT Hub built-in endpoint delivers the device payload directly.
        // It is already a parsed object when the SDK can deserialise it as JSON,
        // or a raw string otherwise.
        const rawEvent = events[i];
        const body =
          typeof rawEvent === 'string' ? JSON.parse(rawEvent) : rawEvent;

        // Fall back to IoT Hub system property if deviceId not in payload
        const sysProps = systemPropsArray[i] ?? {};
        const deviceId =
          body.deviceId ??
          sysProps['iothub-connection-device-id'] ??
          'unknown';

        // Normalise enqueuedTime to ISO-8601 string
        const rawTime = enqueuedTimeArray[i];
        const enqueuedTimeUtc =
          rawTime instanceof Date
            ? rawTime.toISOString()
            : typeof rawTime === 'string'
            ? rawTime
            : new Date().toISOString();

        // Validate required numeric fields
        const temperature =
          typeof body.temperature === 'number' ? body.temperature : null;
        const humidity =
          typeof body.humidity === 'number' ? body.humidity : null;

        const doc = {
          // Stable document key: <deviceId>-<messageId>
          id: `${deviceId}-${body.messageId ?? Date.now()}`,
          messageId: body.messageId ?? null,
          deviceId,
          temperature,
          humidity,
          enqueuedTimeUtc,
        };

        lines.push(JSON.stringify(doc));
      } catch (err) {
        context.log.error(
          `EventHubDecoder: failed to process event[${i}] – ${err.message}`
        );
        // Continue processing the rest of the batch
      }
    }

    if (lines.length === 0) {
      context.log.warn('EventHubDecoder: no valid documents produced from this batch.');
      return;
    }

    // Write all documents as JSON Lines to the output blob
    context.extraOutputs.set(blobOutput, lines.join('\n'));
    context.log(
      `EventHubDecoder: wrote ${lines.length} document(s) to telemetry-decoded.`
    );
  },
});
