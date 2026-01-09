-- IF we need to monitor how good we're at ingest, we can look at the difference between grabbed_ts and ingested_ts
CREATE TABLE IF NOT EXISTS raw_logs
(
    -- timestamp when central log server ingested the log
    `ingested_ts` DateTime64(3),
    -- timestamp when the log was grabbed from the source
    `grabbed_ts`  DateTime64(3),
    -- name of the server
    `server`      String,
    -- name of the host / container
    `host`        String,
    -- application type
    `type`        String,
    -- original log message to be parsed later
    `raw_message` String
) ENGINE = MergeTree()
      PARTITION BY toDate(`ingested_ts`)
      -- this table is for raw logs only, so it does not have to be optimized for search in grabbed_ts
      ORDER BY `ingested_ts`
      -- clean up raw logs after 7 days
      TTL `ingested_ts` + INTERVAL 7 DAY DELETE;

-- example of processed raw logs
CREATE MATERIALIZED VIEW processed_logs_app
            (
             `ts` DateTime64(3),
             `message` String
                ) ENGINE = MergeTree()
        -- faster search by date for processed logs
        PARTITION BY toDate(`ts`)
        ORDER BY `ts`
        -- different storage policy for processed data
        TTL `ts` + INTERVAL 180 DAY DELETE
            POPULATE
AS
-- extraction part
SELECT grabbed_ts  AS ts,
       raw_message AS message
FROM raw_logs
WHERE type = 'app';