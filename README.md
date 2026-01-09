# Log Pipeline

‼️README was generated, pipeline was not

A distributed log aggregation and storage pipeline using Vector and ClickHouse.

## Overview

This project implements a two-tier log collection architecture:
- **Edge Layer**: Vector instances collect logs from multiple sources (files, Docker containers)
- **Central Layer**: Vector central server aggregates logs from edge instances and stores them in ClickHouse
- **Storage Layer**: ClickHouse database with optimized tables for raw and processed logs

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Edge Layer                            │
│                                                              │
│  ┌──────┐    ┌──────┐    ┌─────────────┐                   │
│  │ App  │    │ App2 │    │ ClickHouse  │                   │
│  │      │    │      │    │  Container  │                   │
│  └──┬───┘    └──┬───┘    └──────┬──────┘                   │
│     │           │               │                            │
│     │ stdout    │ stdout        │ docker logs               │
│     │           │               │                            │
│     └───────────┴───────────────┘                            │
│                 │                                            │
│                 ▼                                            │
│         ┌──────────────┐                                     │
│         │ Vector Edge  │                                     │
│         │  - File logs │                                     │
│         │  - Docker    │                                     │
│         └──────┬───────┘                                     │
│                │                                             │
└────────────────┼─────────────────────────────────────────────┘
                 │ HTTP (native protocol, zstd compressed)
                 │ Basic Auth: central_vector_user:pass
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                      Central Layer                           │
│                                                              │
│         ┌──────────────┐                                     │
│         │Vector Central│                                     │
│         │  - HTTP      │                                     │
│         │  - Auth      │                                     │
│         └──────┬───────┘                                     │
│                │                                             │
└────────────────┼─────────────────────────────────────────────┘
                 │ ClickHouse native protocol
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                      Storage Layer                           │
│                                                              │
│         ┌──────────────┐                                     │
│         │  ClickHouse  │                                     │
│         │              │                                     │
│         │ - raw_logs   │ (7 day TTL)                        │
│         │ - processed_ │ (180 day TTL)                      │
│         │   logs_app   │                                     │
│         └──────────────┘                                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Components

### Edge Vector (`vector-edge`)

Collects logs from multiple sources:

- **File Logs**: Monitors `/var/log/shared/app.log` (ignores files older than 10 minutes)
- **Docker Logs**: Captures stdout/stderr from:
  - `app` container
  - `app2` container
  - `clickhouse` container

**Features:**
- Adds metadata (type, host, server, timestamp)
- Buffers up to ~1GB on disk
- Batches logs (10 second timeout)
- Compresses with zstd before sending
- Uses native Vector protocol for efficient transmission
- Basic authentication to central server

### Central Vector (`vector-central`)

Aggregates logs from multiple edge instances:

- **HTTP Server**: Listens on port 8080
- **Authentication**: Basic auth (username: `central_vector_user`)
- **Processing**: Adds ingestion timestamp
- **Storage**: Writes to ClickHouse with batching

**Features:**
- Buffers up to ~5GB on disk
- Batches logs (10MB or 15 seconds)
- Skips unknown fields for forward compatibility

### ClickHouse

Data warehouse for log storage and analysis:

#### Tables

1. **`raw_logs`** - Stores all incoming logs
   - Fields:
     - `ingested_ts` - When central server received the log
     - `grabbed_ts` - When edge collected the log
     - `server` - Edge server identifier
     - `host` - Container/host name
     - `type` - Application type (app, clickhouse, file)
     - `raw_message` - Original log message
   - **TTL**: 7 days
   - **Partitioned by**: `ingested_ts` date
   - **Ordered by**: `ingested_ts`

2. **`processed_logs_app`** - Materialized view for parsed app logs
   - Fields:
     - `ts` - Log timestamp
     - `message` - Extracted message
   - **TTL**: 180 days
   - **Partitioned by**: `ts` date
   - **Ordered by**: `ts`
   - Auto-populated from `raw_logs` where `type = 'app'`

### Demo Applications

- **`app`**: Writes logs to shared file (`/var/log/shared/app.log`) and stdout
- **`app2`**: Writes logs to stdout only

## Prerequisites

- Docker
- Docker Compose

## Quick Start

1. **Start the pipeline:**
   ```bash
   docker-compose up -d
   ```

2. **View logs:**
   ```bash
   # Check Vector edge logs
   docker logs -f vector-edge
   
   # Check Vector central logs
   docker logs -f vector-central
   
   # Check ClickHouse logs
   docker logs -f clickhouse
   ```

3. **Query logs in ClickHouse:**
   ```bash
   docker exec -it clickhouse clickhouse-client --password=default
   ```
   
   Then run queries:
   ```sql
   -- View raw logs
   SELECT * FROM raw_logs ORDER BY ingested_ts DESC LIMIT 10;
   
   -- View processed app logs
   SELECT * FROM processed_logs_app ORDER BY ts DESC LIMIT 10;
   
   -- Check ingestion lag (difference between grabbed and ingested)
   SELECT 
       avg(ingested_ts - grabbed_ts) as avg_lag_ms,
       max(ingested_ts - grabbed_ts) as max_lag_ms
   FROM raw_logs
   WHERE ingested_ts > now() - INTERVAL 1 HOUR;
   
   -- Count logs by type
   SELECT type, count() as count 
   FROM raw_logs 
   GROUP BY type;
   ```

4. **Access ClickHouse HTTP interface:**
   - URL: http://localhost:8123
   - User: `default`
   - Password: `default`

5. **Stop the pipeline:**
   ```bash
   docker-compose down
   ```

## Configuration

### Vector Edge (`vektor/vector-edge.yaml`)

- **Sources**: Define log collection points (files, Docker containers)
- **Transforms**: Add metadata and route logs
- **Sinks**: Configure destination (central Vector server)

Key settings:
- Disk buffer: 1GB
- Batch timeout: 10 seconds
- Compression: zstd
- Central URL: `http://vector-central:8080`

### Vector Central (`vektor/vector-central.yaml`)

- **Sources**: HTTP server for receiving logs from edges
- **Transforms**: Add ingestion timestamp
- **Sinks**: ClickHouse connection

Key settings:
- Disk buffer: 5GB
- Batch size: 10MB
- Batch timeout: 15 seconds
- ClickHouse endpoint: `http://clickhouse:8123`

### ClickHouse (`clickhouse/init_clickhouse.sql`)

- **Tables**: Raw and processed log tables
- **TTL**: Automatic data cleanup (7 days for raw, 180 days for processed)
- **Partitioning**: By date for efficient queries
- **Materialized Views**: Automatic log parsing and transformation

## Network Architecture

Three Docker networks:
- **`ingest`**: Edge → Central communication
- **`storage`**: Central → ClickHouse communication
- **Host bridge**: External access to ClickHouse (port 8123)

## Security Considerations

⚠️ **This is a development setup. For production:**

1. Change default passwords:
   - Vector basic auth (`central_vector_user:pass`)
   - ClickHouse password (`default`)

2. Enable TLS:
   - Use HTTPS for Vector edge → central communication
   - Consider putting central Vector behind a reverse proxy with TLS

3. Network security:
   - Don't expose ClickHouse port publicly
   - Use firewall rules to restrict access
   - Consider using Docker secrets for credentials

4. Resource limits:
   - Add CPU/memory limits to containers
   - Monitor disk buffer usage

## Monitoring

### Vector Metrics

Vector exposes metrics that can be scraped:
- Add metrics endpoint in Vector configuration
- Use Prometheus/Grafana for visualization

### ClickHouse Monitoring

Monitor ingestion performance:
```sql
-- Ingestion lag monitoring
SELECT 
    toStartOfMinute(ingested_ts) as minute,
    count() as log_count,
    avg(ingested_ts - grabbed_ts) as avg_lag_ms
FROM raw_logs
WHERE ingested_ts > now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute DESC;

-- Logs per server
SELECT 
    server,
    type,
    count() as count
FROM raw_logs
WHERE ingested_ts > now() - INTERVAL 1 HOUR
GROUP BY server, type;
```

## Scaling

### Horizontal Scaling

1. **Multiple Edge Vectors**: Deploy additional edge Vector instances in different locations
2. **Load Balancing**: Put multiple central Vector instances behind a load balancer
3. **ClickHouse Cluster**: Use ClickHouse clustering for high availability

### Vertical Scaling

1. Increase disk buffer sizes for higher throughput
2. Adjust batch sizes and timeouts for lower latency
3. Add more CPU/memory to ClickHouse for complex queries

## Troubleshooting

### Logs not appearing in ClickHouse

1. Check Vector edge can connect to central:
   ```bash
   docker logs vector-edge | grep error
   ```

2. Check Vector central can connect to ClickHouse:
   ```bash
   docker logs vector-central | grep error
   ```

3. Verify ClickHouse is accepting connections:
   ```bash
   docker exec clickhouse clickhouse-client --query "SELECT 1"
   ```

### High disk buffer usage

1. Check ClickHouse is processing inserts:
   ```sql
   SELECT * FROM system.query_log 
   ORDER BY event_time DESC LIMIT 10;
   ```

2. Monitor Vector central metrics:
   ```bash
   docker logs vector-central | grep "buffer"
   ```

### Authentication errors

1. Verify credentials match in:
   - `vektor/vector-edge.yaml` (sink auth)
   - `vektor/vector-central.yaml` (source auth)

## Development

### Adding New Log Sources

1. Add a new source in `vektor/vector-edge.yaml`:
   ```yaml
   sources:
     new_source:
       type: "file"  # or docker_logs, syslog, etc.
       # ... configuration
   ```

2. Add a transform to parse and route:
   ```yaml
   transforms:
     new_parse:
       type: "remap"
       inputs:
         - new_source
       source: |
         .type = "new_type"
   ```

3. Add to funnel_all inputs

### Creating New Materialized Views

1. Add to `clickhouse/init_clickhouse.sql`:
   ```sql
   CREATE MATERIALIZED VIEW processed_logs_new_type
   (
       ts DateTime64(3),
       field1 String,
       field2 Int64
   ) ENGINE = MergeTree()
   PARTITION BY toDate(ts)
   ORDER BY ts
   TTL ts + INTERVAL 180 DAY DELETE
   POPULATE
   AS
   SELECT 
       grabbed_ts AS ts,
       extractValue(raw_message, 'field1') AS field1,
       toInt64(extractValue(raw_message, 'field2')) AS field2
   FROM raw_logs
   WHERE type = 'new_type';
   ```

