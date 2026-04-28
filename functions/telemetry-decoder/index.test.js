"use strict";

const func = require("./index");

/**
 * Minimal context mock that captures log output and output bindings.
 */
function makeContext(blobName = "test-blob") {
  const logs = [];
  const warns = [];
  return {
    log: Object.assign((...args) => logs.push(args.join(" ")), {
      warn: (...args) => warns.push(args.join(" ")),
    }),
    bindingData: { name: blobName },
    bindings: {},
    _logs: logs,
    _warns: warns,
  };
}

/**
 * Build a realistic IoT Hub envelope whose Body is the Base64-encoded
 * device payload produced by the Raspberry Pi Web Simulator.
 */
function makeEnvelope(payload) {
  const bodyB64 = Buffer.from(JSON.stringify(payload)).toString("base64");
  return {
    EnqueuedTimeUtc: "2026-04-28T10:30:00.000Z",
    Properties: {},
    SystemProperties: { connectionDeviceId: payload.deviceId },
    Body: bodyB64,
  };
}

describe("telemetry-decoder function", () => {
  test("decodes a single valid envelope with temperature > 30", async () => {
    const payload = {
      messageId: 42,
      deviceId: "Raspberry Pi Web Client",
      temperature: 35.7,
      humidity: 55.2,
    };
    const envelope = makeEnvelope(payload);
    const inputBlob = Buffer.from(JSON.stringify(envelope) + "\n", "utf8");

    const ctx = makeContext();
    await func(ctx, inputBlob);

    expect(ctx.bindings.outputBlob).toBeTruthy();
    const outputRecord = JSON.parse(ctx.bindings.outputBlob.trim());

    expect(outputRecord.temperature).toBeCloseTo(35.7);
    expect(outputRecord.humidity).toBeCloseTo(55.2);
    expect(outputRecord.deviceId).toBe("Raspberry Pi Web Client");
    expect(outputRecord.messageId).toBe(42);
    expect(typeof outputRecord.id).toBe("string");
    expect(outputRecord.id.length).toBeGreaterThan(0);
  });

  test("decodes a single valid envelope with temperature <= 30", async () => {
    const payload = {
      messageId: 1,
      deviceId: "Raspberry Pi Web Client",
      temperature: 24.628269748142735,
      humidity: 61.215245632443775,
    };
    const envelope = makeEnvelope(payload);
    const inputBlob = Buffer.from(JSON.stringify(envelope) + "\n", "utf8");

    const ctx = makeContext();
    await func(ctx, inputBlob);

    const outputRecord = JSON.parse(ctx.bindings.outputBlob.trim());
    expect(outputRecord.temperature).toBeCloseTo(24.63, 1);
    expect(outputRecord.humidity).toBeCloseTo(61.22, 1);
  });

  test("decodes multiple envelopes from one blob (newline-delimited)", async () => {
    const payloads = [
      { messageId: 1, deviceId: "Raspberry Pi Web Client", temperature: 22.1, humidity: 58.0 },
      { messageId: 2, deviceId: "Raspberry Pi Web Client", temperature: 31.5, humidity: 62.3 },
      { messageId: 3, deviceId: "Raspberry Pi Web Client", temperature: 28.9, humidity: 60.1 },
    ];
    const blobContent = payloads
      .map((p) => JSON.stringify(makeEnvelope(p)))
      .join("\n") + "\n";
    const inputBlob = Buffer.from(blobContent, "utf8");

    const ctx = makeContext();
    await func(ctx, inputBlob);

    const outputLines = ctx.bindings.outputBlob.trim().split("\n");
    expect(outputLines).toHaveLength(3);

    const records = outputLines.map((l) => JSON.parse(l));
    expect(records[0].temperature).toBeCloseTo(22.1);
    expect(records[1].temperature).toBeCloseTo(31.5);
    expect(records[2].temperature).toBeCloseTo(28.9);
  });

  test("skips lines with missing Body and continues processing", async () => {
    const good = makeEnvelope({ messageId: 10, deviceId: "dev-1", temperature: 33.0, humidity: 50.0 });
    const bad = { EnqueuedTimeUtc: "2026-04-28T10:31:00.000Z", Body: null };
    const blobContent = [good, bad].map((e) => JSON.stringify(e)).join("\n") + "\n";
    const inputBlob = Buffer.from(blobContent, "utf8");

    const ctx = makeContext();
    await func(ctx, inputBlob);

    const outputLines = ctx.bindings.outputBlob.trim().split("\n");
    expect(outputLines).toHaveLength(1);
    expect(JSON.parse(outputLines[0]).temperature).toBeCloseTo(33.0);
    expect(ctx._warns.length).toBeGreaterThan(0);
  });

  test("emits empty output when all envelopes are invalid", async () => {
    const inputBlob = Buffer.from('{"invalid":"no-body"}\n', "utf8");
    const ctx = makeContext();
    await func(ctx, inputBlob);
    expect(ctx.bindings.outputBlob).toBe("");
  });

  test("document id is stable across two identical calls (idempotent indexing)", async () => {
    const payload = { messageId: 99, deviceId: "dev-stable", temperature: 40.0, humidity: 45.0 };
    const inputBlob = Buffer.from(JSON.stringify(makeEnvelope(payload)) + "\n", "utf8");

    const ctx1 = makeContext();
    const ctx2 = makeContext();
    await func(ctx1, inputBlob);
    await func(ctx2, inputBlob);

    const rec1 = JSON.parse(ctx1.bindings.outputBlob.trim());
    const rec2 = JSON.parse(ctx2.bindings.outputBlob.trim());
    expect(rec1.id).toBe(rec2.id);
  });

  test("id field contains only URL-safe characters", async () => {
    const payload = { messageId: 7, deviceId: "Raspberry Pi Web Client", temperature: 37.2, humidity: 70.0 };
    const inputBlob = Buffer.from(JSON.stringify(makeEnvelope(payload)) + "\n", "utf8");
    const ctx = makeContext();
    await func(ctx, inputBlob);
    const rec = JSON.parse(ctx.bindings.outputBlob.trim());
    expect(rec.id).toMatch(/^[A-Za-z0-9_]+$/);
  });
});
