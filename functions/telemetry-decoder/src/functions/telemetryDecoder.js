/**
 * Azure Function: telemetryDecoder
 *
 * Blob-triggered on the `telemetry-raw` container.
 * Each blob written by IoT Hub routing contains newline-delimited JSON where
 * every line is an IoT Hub message envelope:
 *
 *   { "EnqueuedTimeUtc": "...", "Properties": {}, "SystemProperties": {},
 *     "Body": "<base64-encoded inner payload>" }
 *
 * The inner payload (after base64 decoding) matches the message sent by the
 * Raspberry Pi simulator:
 *   { "messageId": 1, "deviceId": "...", "temperature": 24.6, "humidity": 61.2 }
 *
 * This function decodes every envelope line and writes the clean, flat JSON
 * (one document per line) to the `telemetry-decoded` container so that
 * Azure AI Search can index the fields directly.
 */

'use strict';

const { app } = require('@azure/functions');
const { BlobServiceClient } = require('@azure/storage-blob');

app.storageBlob('telemetryDecoder', {
  path: 'telemetry-raw/{name}',
  connection: 'AzureWebJobsStorage',
  handler: async (blob, context) => {
    const blobName = context.triggerMetadata.name;
    context.log(`Processing blob: ${blobName}, size: ${blob.length} bytes`);

    const content = blob.toString('utf-8');
    const lines = content.split('\n').filter((line) => line.trim().length > 0);

    const decodedLines = [];

    for (const line of lines) {
      try {
        const envelope = JSON.parse(line);

        if (!envelope.Body) {
          context.log.warn('Envelope line is missing Body field – skipping');
          continue;
        }

        // Decode the base64-encoded inner payload
        const bodyBuffer = Buffer.from(envelope.Body, 'base64');
        const bodyJson = JSON.parse(bodyBuffer.toString('utf-8'));

        // Build a stable, URL-safe document key
        const rawId = `${bodyJson.deviceId ?? ''}:${bodyJson.messageId ?? ''}:${envelope.EnqueuedTimeUtc ?? Date.now()}`;
        const id = Buffer.from(rawId)
          .toString('base64')
          .replace(/\+/g, '-')
          .replace(/\//g, '_')
          .replace(/=/g, '');

        const doc = {
          id,
          messageId: bodyJson.messageId !== undefined ? String(bodyJson.messageId) : null,
          deviceId: bodyJson.deviceId ?? null,
          temperature: bodyJson.temperature ?? null,
          humidity: bodyJson.humidity ?? null,
          enqueuedTimeUtc: envelope.EnqueuedTimeUtc ?? null,
        };

        decodedLines.push(JSON.stringify(doc));
      } catch (err) {
        context.log.error(`Failed to process line: ${err.message}`);
      }
    }

    if (decodedLines.length === 0) {
      context.log('No valid documents decoded – nothing written to telemetry-decoded');
      return;
    }

    // Write clean newline-delimited JSON to telemetry-decoded
    const outputContent = decodedLines.join('\n');
    const connectionString = process.env.AzureWebJobsStorage;

    const blobServiceClient = BlobServiceClient.fromConnectionString(connectionString);
    const containerClient = blobServiceClient.getContainerClient('telemetry-decoded');

    // Ensure the container exists (idempotent)
    await containerClient.createIfNotExists();

    const blockBlobClient = containerClient.getBlockBlobClient(blobName);
    await blockBlobClient.upload(outputContent, Buffer.byteLength(outputContent, 'utf-8'), {
      blobHTTPHeaders: { blobContentType: 'application/x-ndjson' },
    });

    context.log(
      `Wrote ${decodedLines.length} document(s) to telemetry-decoded/${blobName}`
    );
  },
});
