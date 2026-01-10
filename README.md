# Log Pipeline

‼️README was generated, pipeline was not

A distributed log aggregation and storage pipeline using Vector and ClickHouse.

## Overview

This project implements a two-tier log collection and metrics architecture:
- **Edge Layer**: Vector instances collect logs from multiple sources (files, Docker containers) and host metrics
- **Central Layer**: Vector central server aggregates logs and metrics from edge instances and stores them in ClickHouse
- **Storage Layer**: ClickHouse database with optimized tables for raw and processed logs, plus host metrics

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Edge Layer                           │
│                                                             │
│  ┌──────┐    ┌──────┐    ┌─────────────┐                    │
│  │ App  │    │ App2 │    │ ClickHouse  │                    │
│  │      │    │      │    │  Container  │                    │
│  └──┬───┘    └──┬───┘    └──────┬──────┘                    │
│     │           │               │                           │
│     │ stdout    │ stdout        │ docker logs               │
│     │           │               │                           │
│     └───────────┴───────────────┘                           │
│                 │                                           │
│                 ▼                                           │
│         ┌──────────────┐         ┌───────────────┐          │
│         │ Vector Edge  │         │Vector Metrics │          │
│         │  - File logs │         │ - CPU         │          │
│         │  - Docker    │         │ - Memory      │          │
│         └──────┬───────┘         │ - Disk        │          │
│                │                 │ - Network     │          │
│                │                 │ - Filesystem  │          │
│                │                 └───────┬───────┘          │
│                │                         │                  │
└────────────────┼─────────────────────────┼──────────────────┘
                 │ HTTP (native, zstd)     │ HTTP (native, zstd)
                 │ Basic Auth              │ Basic Auth
                 ▼                         ▼
┌──────────────────────────────────────────────────────────────┐
│                      Central Layer                           │
│                                                              │
│         ┌──────────────┐                                     │
│         │Vector Central│                                     │
│         │  - HTTP      │                                     │
│         │  - Auth      │                                     │
│         │  - Routes    │                                     │
│         │    logs &    │                                     │
│         │    metrics   │                                     │
│         └──────┬───────┘                                     │
│                │                                             │
└────────────────┼─────────────────────────────────────────────┘
                 │ ClickHouse native protocol
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                      Storage Layer                          │
│                                                             │
│         ┌──────────────┐                                    │
│         │  ClickHouse  │                                    │
│         │              │                                    │
│         │ - raw_logs   │ (7 day TTL)                        │
│         │ - processed_ │ (180 day TTL)                      │
│         │   logs_app   │                                    │
│         │ - raw_host_  │ (30 day TTL)                       │
│         │   metrics    │                                    │
│         └──────────────┘                                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```
│         │   logs_app   │                                    │
│         └──────────────┘                                    │
│                                                             │
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
- Routes logs and metrics to separate ClickHouse tables
- Converts metrics to log format for ClickHouse ingestion

### Metrics Vector (`vector-metrics`)

Collects host-level performance metrics:

- **Collectors**: 
  - **CPU**: Usage, load averages
  - **Memory**: RAM usage, swap, available memory
  - **Filesystem**: Disk space, inodes
  - **Disk**: I/O operations, throughput
  - **Network**: Bytes sent/received, packets, errors
  - **Load**: System load averages
- **Scrape Interval**: 15 seconds

**Features:**
- Runs in host network mode for accurate network metrics
- Adds server tag for identification
- Buffers up to ~1GB on disk
- Batches metrics (10 second timeout)
- Compresses with zstd before sending
- Uses native Vector protocol
- Sends to same central endpoint as logs

**Note**: In production, `vector-metrics` and `vector-edge` should run in the same container. They are separated here for educational purposes to clearly demonstrate the different collection patterns.

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

3. **`raw_host_metrics`** - Stores host performance metrics
   - Fields:
     - `timestamp` - When metric was collected
     - `server` - Edge server identifier
     - `host` - Host/container name
     - `name` - Metric name (e.g., `cpu_usage_idle`, `memory_available_bytes`)
     - `kind` - Metric type (gauge, counter)
     - `value` - Numeric metric value
     - `tags` - Additional metadata as key-value map
   - **TTL**: 30 days
   - **Partitioned by**: `timestamp` date (YYYYMMDD)
   - **Ordered by**: `server`, `host`, `name`, `timestamp`

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
   
   # Check Vector metrics logs
   docker logs -f vector-metrics
   
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
   
   -- View host metrics
   SELECT * FROM raw_host_metrics ORDER BY timestamp DESC LIMIT 10;
   
   -- Query CPU metrics
   SELECT 
       timestamp,
       server,
       name,
       value
   FROM raw_host_metrics
   WHERE name LIKE 'cpu%'
   ORDER BY timestamp DESC
   LIMIT 20;
   
   -- Query memory usage over time
   SELECT 
       toStartOfMinute(timestamp) as minute,
       server,
       avg(value) as avg_value
   FROM raw_host_metrics
   WHERE name = 'memory_used_bytes'
     AND timestamp > now() - INTERVAL 1 HOUR
   GROUP BY minute, server
   ORDER BY minute DESC;
   
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

### Vector Metrics (`vektor/vector-metrics.yaml`)

- **Sources**: Host metrics collector (CPU, memory, disk, network, filesystem, load)
- **Transforms**: Add server tag for identification
- **Sinks**: HTTP endpoint to central Vector server

Key settings:
- Scrape interval: 15 seconds
- Disk buffer: 1GB
- Batch timeout: 10 seconds
- Compression: zstd
- Central URL: `http://localhost:8080` (uses host network mode)
- Network mode: host (required for accurate network metrics)

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

**Note**: `vector-metrics` runs in host network mode to accurately collect network statistics. It connects to `vector-central` via `localhost:8080`.

## Metrics Collection

The metrics system collects comprehensive host-level performance data from each edge server.

### Available Metrics

#### CPU Metrics
- `cpu_usage_idle` - Percentage of time CPU is idle
- `cpu_usage_user` - Percentage of time CPU spent in user mode
- `cpu_usage_system` - Percentage of time CPU spent in system mode
- `load1`, `load5`, `load15` - System load averages

#### Memory Metrics
- `memory_total_bytes` - Total system memory
- `memory_available_bytes` - Available memory for new processes
- `memory_free_bytes` - Free memory
- `memory_used_bytes` - Used memory
- `memory_swap_total_bytes` - Total swap space
- `memory_swap_free_bytes` - Free swap space

#### Disk Metrics
- `disk_read_bytes` - Bytes read from disk
- `disk_written_bytes` - Bytes written to disk
- `disk_read_ops` - Read operations count
- `disk_write_ops` - Write operations count

#### Filesystem Metrics
- `filesystem_total_bytes` - Total filesystem size
- `filesystem_free_bytes` - Free space on filesystem
- `filesystem_used_bytes` - Used space on filesystem
- `filesystem_inodes_total` - Total inodes
- `filesystem_inodes_free` - Free inodes

#### Network Metrics
- `network_receive_bytes` - Bytes received on network interface
- `network_transmit_bytes` - Bytes transmitted on network interface
- `network_receive_packets` - Packets received
- `network_transmit_packets` - Packets transmitted
- `network_receive_errors` - Receive errors
- `network_transmit_errors` - Transmit errors

### Metrics Architecture

```
┌─────────────────────────┐
│   Host System           │
│                         │
│  /proc  /sys  /         │
│    │      │     │       │
└────┼──────┼─────┼───────┘
     │      │     │
     └──────┴─────┘
            │
    ┌───────▼────────┐
    │ Vector Metrics │
    │   (host mode)  │
    │                │
    │ - Scrape: 15s  │
    │ - Buffer: 1GB  │
    │ - Compress     │
    └───────┬────────┘
            │ HTTP + native + zstd
            │ localhost:8080
    ┌───────▼────────┐
    │ Vector Central │
    │                │
    │ - Filter       │
    │ - Transform    │
    └───────┬────────┘
            │ ClickHouse protocol
    ┌───────▼────────┐
    │  ClickHouse    │
    │  raw_host_     │
    │  metrics       │
    │  (30d TTL)     │
    └────────────────┘
```

### Querying Metrics

Example queries for common monitoring scenarios:

```sql
-- Current CPU usage per server
SELECT 
    server,
    name,
    value,
    timestamp
FROM raw_host_metrics
WHERE name = 'cpu_usage_idle'
  AND timestamp > now() - INTERVAL 5 MINUTE
ORDER BY timestamp DESC
LIMIT 10;

-- Memory usage trends (last hour)
SELECT 
    toStartOfMinute(timestamp) as minute,
    server,
    avg(value) / 1024 / 1024 / 1024 as avg_gb
FROM raw_host_metrics
WHERE name = 'memory_used_bytes'
  AND timestamp > now() - INTERVAL 1 HOUR
GROUP BY minute, server
ORDER BY minute DESC;

-- Disk I/O summary
SELECT 
    server,
    name,
    max(value) - min(value) as delta
FROM raw_host_metrics
WHERE name IN ('disk_read_bytes', 'disk_written_bytes')
  AND timestamp > now() - INTERVAL 1 HOUR
GROUP BY server, name;

-- Network throughput (bytes per minute)
SELECT 
    toStartOfMinute(timestamp) as minute,
    server,
    tags['interface'] as interface,
    max(value) - min(value) as bytes_per_minute
FROM raw_host_metrics
WHERE name IN ('network_receive_bytes', 'network_transmit_bytes')
  AND timestamp > now() - INTERVAL 1 HOUR
GROUP BY minute, server, interface, name
ORDER BY minute DESC;

-- Filesystem usage percentage
SELECT 
    server,
    tags['filesystem'] as filesystem,
    tags['device'] as device,
    max(CASE WHEN name = 'filesystem_used_bytes' THEN value END) as used,
    max(CASE WHEN name = 'filesystem_total_bytes' THEN value END) as total,
    (used / total) * 100 as usage_percent
FROM raw_host_metrics
WHERE name IN ('filesystem_used_bytes', 'filesystem_total_bytes')
  AND timestamp > now() - INTERVAL 5 MINUTE
GROUP BY server, filesystem, device
HAVING usage_percent > 0
ORDER BY usage_percent DESC;
```

### Metrics Best Practices

1. **Retention**: Metrics are kept for 30 days by default. Adjust TTL based on your needs
2. **Aggregation**: Create materialized views for pre-aggregated metrics (hourly/daily averages)
3. **Alerting**: Query metrics at regular intervals and trigger alerts for thresholds
4. **Downsampling**: For long-term storage, consider creating tables with reduced granularity
5. **Host Network Mode**: Required for `vector-metrics` to accurately collect network interface stats

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

