-- 1. The Target Table (Where data lives)
CREATE TABLE IF NOT EXISTS app_logs (
    timestamp DateTime,
    level String,
    message String,
    container_id String
) ENGINE = MergeTree()
ORDER BY timestamp;

-- 2. The Kafka Engine (The Pipe)
CREATE TABLE IF NOT EXISTS app_logs_queue (
    timestamp DateTime,
    level String,
    message String,
    container_id String
) ENGINE = Kafka
SETTINGS kafka_broker_list = 'redpanda:9092',
         kafka_topic_list = 'app_logs',
         kafka_group_name = 'clickhouse_group',
         kafka_format = 'JSONEachRow';

-- 3. The Materialized View (The Mover)
CREATE MATERIALIZED VIEW IF NOT EXISTS app_logs_mv TO app_logs AS
SELECT * FROM app_logs_queue;