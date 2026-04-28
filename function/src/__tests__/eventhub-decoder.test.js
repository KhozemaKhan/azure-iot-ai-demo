'use strict';

/**
 * Unit tests for the EventHubDecoder logic.
 *
 * These tests exercise the document-transformation logic in isolation,
 * without requiring an actual Azure Functions runtime or Event Hub.
 */

// ── Helper: replicate the core transformation from eventhub-decoder.js ─────────
function transformEvent(rawEvent, sysProps, rawTime) {
  const body =
    typeof rawEvent === 'string' ? JSON.parse(rawEvent) : rawEvent;

  const deviceId =
    body.deviceId ??
    (sysProps && sysProps['iothub-connection-device-id']) ??
    'unknown';

  const enqueuedTimeUtc =
    rawTime instanceof Date
      ? rawTime.toISOString()
      : typeof rawTime === 'string'
      ? rawTime
      : new Date().toISOString();

  return {
    id: `${deviceId}-${body.messageId ?? 0}`,
    messageId: body.messageId ?? null,
    deviceId,
    temperature: typeof body.temperature === 'number' ? body.temperature : null,
    humidity: typeof body.humidity === 'number' ? body.humidity : null,
    enqueuedTimeUtc,
  };
}

// ─────────────────────────────────────────────────────────────────────────────

describe('EventHubDecoder transformation logic', () => {
  test('transforms a plain JSON object with all fields', () => {
    const event = {
      messageId: 42,
      deviceId: 'Raspberry Pi Web Client',
      temperature: 35.5,
      humidity: 60.2,
    };
    const time = '2026-04-28T15:28:49.000Z';

    const doc = transformEvent(event, {}, time);

    expect(doc.id).toBe('Raspberry Pi Web Client-42');
    expect(doc.messageId).toBe(42);
    expect(doc.deviceId).toBe('Raspberry Pi Web Client');
    expect(doc.temperature).toBe(35.5);
    expect(doc.humidity).toBe(60.2);
    expect(doc.enqueuedTimeUtc).toBe(time);
  });

  test('parses a JSON string payload correctly', () => {
    const event = JSON.stringify({
      messageId: 1,
      deviceId: 'raspberry-pi-simulator',
      temperature: 31.93,
      humidity: 75.77,
    });

    const doc = transformEvent(event, {}, '2026-04-28T15:28:49.558Z');

    expect(doc.messageId).toBe(1);
    expect(doc.temperature).toBeCloseTo(31.93);
    expect(doc.deviceId).toBe('raspberry-pi-simulator');
  });

  test('falls back to system property for deviceId when missing in body', () => {
    const event = { messageId: 7, temperature: 28.0, humidity: 55.0 };
    const sysProps = { 'iothub-connection-device-id': 'device-from-sysProps' };

    const doc = transformEvent(event, sysProps, '2026-04-28T10:00:00Z');

    expect(doc.deviceId).toBe('device-from-sysProps');
    expect(doc.id).toBe('device-from-sysProps-7');
  });

  test('uses "unknown" deviceId when not present anywhere', () => {
    const event = { messageId: 3, temperature: 22.0, humidity: 60.0 };

    const doc = transformEvent(event, {}, '2026-04-28T10:00:00Z');

    expect(doc.deviceId).toBe('unknown');
  });

  test('sets temperature and humidity to null when not numeric', () => {
    const event = {
      messageId: 5,
      deviceId: 'test-device',
      temperature: 'N/A',
      humidity: undefined,
    };

    const doc = transformEvent(event, {}, '2026-04-28T10:00:00Z');

    expect(doc.temperature).toBeNull();
    expect(doc.humidity).toBeNull();
  });

  test('converts Date object enqueuedTime to ISO string', () => {
    const event = { messageId: 9, deviceId: 'dev', temperature: 30, humidity: 50 };
    const time = new Date('2026-04-28T12:00:00Z');

    const doc = transformEvent(event, {}, time);

    expect(doc.enqueuedTimeUtc).toBe('2026-04-28T12:00:00.000Z');
  });

  test('temperature gt 30 is detectable after transformation', () => {
    const events = [
      { messageId: 1, deviceId: 'dev', temperature: 30.86, humidity: 63.84 },
      { messageId: 2, deviceId: 'dev', temperature: 31.94, humidity: 75.77 },
      { messageId: 3, deviceId: 'dev', temperature: 22.65, humidity: 79.83 },
      { messageId: 4, deviceId: 'dev', temperature: 27.84, humidity: 73.74 },
    ];

    const docs = events.map((e) =>
      transformEvent(e, {}, '2026-04-28T15:28:49.000Z')
    );

    const highTemp = docs.filter((d) => d.temperature > 30);
    expect(highTemp).toHaveLength(2);
    expect(highTemp[0].temperature).toBeCloseTo(30.86);
    expect(highTemp[1].temperature).toBeCloseTo(31.94);
  });
});
