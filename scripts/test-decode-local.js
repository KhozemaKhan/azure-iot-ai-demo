#!/usr/bin/env node
// =============================================================================
// test-decode-local.js – Validate the telemetry-decoder logic without Azure
// =============================================================================
// Run:
//   node scripts/test-decode-local.js
// =============================================================================
'use strict';

// ── Helpers (same logic as telemetryDecoder.js) ────────────────────────────

function decodeEnvelope(line) {
  const envelope = JSON.parse(line);
  if (!envelope.Body) throw new Error('Missing Body field');

  const bodyBuffer = Buffer.from(envelope.Body, 'base64');
  const bodyJson   = JSON.parse(bodyBuffer.toString('utf-8'));

  const rawId = `${bodyJson.deviceId ?? ''}:${bodyJson.messageId ?? ''}:${envelope.EnqueuedTimeUtc ?? Date.now()}`;
  const id    = Buffer.from(rawId)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g,  '');

  return {
    id,
    messageId:      bodyJson.messageId  !== undefined ? String(bodyJson.messageId) : null,
    deviceId:       bodyJson.deviceId   ?? null,
    temperature:    bodyJson.temperature ?? null,
    humidity:       bodyJson.humidity    ?? null,
    enqueuedTimeUtc: envelope.EnqueuedTimeUtc ?? null,
  };
}

// ── Build a sample IoT Hub envelope (as written to telemetry-raw) ──────────

const innerPayload = {
  messageId:   1,
  deviceId:    'Raspberry Pi Web Client',
  temperature: 24.628269748142735,
  humidity:    61.215245632443775,
};

const envelope = {
  EnqueuedTimeUtc:   '2026-04-28T10:30:00.000Z',
  Properties:        {},
  SystemProperties:  {
    connectionDeviceId: 'raspberry-pi-simulator',
    enqueuedTime:       '2026-04-28T10:30:00.000Z',
  },
  Body: Buffer.from(JSON.stringify(innerPayload)).toString('base64'),
};

// A second message (temperature above 30 °C for filter testing)
const innerPayload2 = {
  messageId:   2,
  deviceId:    'Raspberry Pi Web Client',
  temperature: 33.5,
  humidity:    55.0,
};

const envelope2 = {
  EnqueuedTimeUtc:   '2026-04-28T10:30:05.000Z',
  Properties:        {},
  SystemProperties:  {
    connectionDeviceId: 'raspberry-pi-simulator',
    enqueuedTime:       '2026-04-28T10:30:05.000Z',
  },
  Body: Buffer.from(JSON.stringify(innerPayload2)).toString('base64'),
};

// ── Simulate a newline-delimited blob ────────────────────────────────────────

const blobContent = [JSON.stringify(envelope), JSON.stringify(envelope2)].join('\n');

console.log('=== Input blob (telemetry-raw) ===');
console.log(blobContent);
console.log('');

// ── Decode ──────────────────────────────────────────────────────────────────

const lines = blobContent.split('\n').filter((l) => l.trim().length > 0);
const docs  = lines.map(decodeEnvelope);

const outputContent = docs.map((d) => JSON.stringify(d)).join('\n');

console.log('=== Output blob (telemetry-decoded) ===');
console.log(outputContent);
console.log('');

// ── Validate non-null fields ────────────────────────────────────────────────

let allPassed = true;
const requiredFields = ['id', 'messageId', 'deviceId', 'temperature', 'humidity', 'enqueuedTimeUtc'];

docs.forEach((doc, idx) => {
  requiredFields.forEach((field) => {
    if (doc[field] === null || doc[field] === undefined) {
      console.error(`[FAIL] doc[${idx}].${field} is null/undefined`);
      allPassed = false;
    }
  });
});

if (allPassed) {
  console.log('[PASS] All required fields are populated in every decoded document.');
} else {
  process.exit(1);
}

// ── Sample filter test ──────────────────────────────────────────────────────

const hotDocs = docs.filter((d) => d.temperature > 30);
console.log(`\n[INFO] Documents with temperature > 30: ${hotDocs.length}`);
hotDocs.forEach((d) =>
  console.log(`  deviceId=${d.deviceId}  temperature=${d.temperature}  messageId=${d.messageId}`)
);
