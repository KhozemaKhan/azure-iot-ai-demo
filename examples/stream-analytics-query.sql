-- Stream Analytics query for the IoT telemetry pipeline
-- Input:  iotHubInput  (IoT Hub built-in Event Hub-compatible endpoint)
-- Output: blobOutput   (Blob Storage container: telemetry-decoded)
--
-- This query:
--   1. Projects only the fields we need (discards IoT Hub metadata noise)
--   2. Applies explicit CAST to guarantee correct output types regardless of
--      what type ASA infers from early events
--   3. Adds EventEnqueuedUtcTime as a stable, reliable timestamp
--
-- The output format (Line separated JSON) produces one record per line:
--   {"messageId":1,"deviceId":"Raspberry Pi Web Client","temperature":30.85,...}
--   {"messageId":2,"deviceId":"Raspberry Pi Web Client","temperature":31.93,...}
--
-- This format is consumed by the Azure AI Search indexer with parsingMode=jsonLines

SELECT
    CAST(messageId       AS bigint)       AS messageId,
    CAST(deviceId        AS nvarchar(max)) AS deviceId,
    CAST(temperature     AS float)         AS temperature,
    CAST(humidity        AS float)         AS humidity,
    EventEnqueuedUtcTime                   AS enqueuedTimeUtc
INTO
    [blobOutput]
FROM
    [iotHubInput]
