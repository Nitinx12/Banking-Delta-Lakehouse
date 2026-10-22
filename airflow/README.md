# Banking-Delta Airflow

Orchestration layer for the Banking-Delta daily pipeline. Airflow only triggers existing entry points (`main.py`, `scripts/run_jobs.py`, `src/jobs/publish_marts.py`); no pipeline logic lives here.

## Quick Start

### Prerequisites

- Docker Desktop (Windows/macOS) or Docker Engine + Compose plugin (Linux)
- Git
- Python 3.13+ (for generating secrets locally)

### 1. Configure Environment

```bash
cd airflow

# Copy template and secure it
cp .env.airflow.example .env.airflow
chmod 600 .env.airflow
```

**Edit `.env.airflow` and fill every value** — no placeholders allowed in production. Key items:

| Variable | Purpose |
|----------|---------|
| `AIRFLOW_DB_PASSWORD` | Postgres metadata DB password |
| `REDIS_PASSWORD` | Celery broker password |
| `AIRFLOW__CORE__FERNET_KEY` | `python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` |
| `AIRFLOW__API_AUTH__JWT_SECRET` | `python -c "import secrets; print(secrets.token_urlsafe(64))"` |
| `AIRFLOW__API__SECRET_KEY` | `python -c "import secrets; print(secrets.token_urlsafe(64))"` |
| `SMTP_PASSWORD` | Gmail App Password from https://myaccount.google.com/apppasswords |
| `PG_PASS`, `MYSQL_PASSWORD`, `MONGO_URI`, `DATABRICKS_TOKEN` | Source/warehouse credentials |

### 2. Build and Start (Development Mode)

```bash
# From airflow/ directory
export AIRFLOW_IMAGE_TAG=$(git rev-parse --short HEAD)
export GIT_SHA=$AIRFLOW_IMAGE_TAG

# Build images
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow build

# Initialize metadata DB (run once, must exit 0)
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow up airflow-init

# Start all services in background
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow up -d
```

### 3. Verify Startup

```bash
# Check all containers healthy
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow ps

# Expected: 7 containers running (apiserver, scheduler, dag-processor, triggerer, worker, db, redis)
```

**Access UI:** http://localhost:8080  
**Login:** `AIRFLOW_ADMIN_USERNAME` / `AIRFLOW_ADMIN_PASSWORD` from `.env.airflow`

---

## Docker Compose Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Base production-ready config |
| `docker-compose.dev.yml` | Dev overrides: bind-mounts source code, adds `host.docker.internal` for local DBs |

**Usage patterns:**

```bash
# Development (code changes reflect instantly)
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow up -d

# Production-like (no bind mounts, uses baked image)
docker compose -f docker-compose.yml --env-file .env.airflow up -d

# With custom tag
AIRFLOW_IMAGE_TAG=v1.2.3 docker compose -f docker-compose.yml --env-file .env.airflow up -d
```

---

## Container Management

### Status & Logs

```bash
# List containers with health status
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow ps

# Follow logs for a specific service
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow logs -f airflow-scheduler
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow logs -f airflow-worker

# Show last 100 lines
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow logs --tail=100 airflow-apiserver
```

### Restart Individual Services

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow restart airflow-scheduler
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow restart airflow-worker
```

### Stop / Remove

```bash
# Stop containers, keep volumes (metadata, Spark cache, reports)
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow down

# Full cleanup: remove containers, networks, AND volumes (metadata DB, Redis, Spark cache, reports)
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow down -v

# Remove images too
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow down -v --rmi all
```

### Rebuild After Code Changes

```bash
# Rebuild only the Airflow image (dev mode picks up code via bind mounts automatically)
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow build

# Full rebuild from scratch
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow build --no-cache
```

---

## DAG Management

### List DAGs

```bash
# Via CLI (inside scheduler container)
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler airflow dags list

# Show import errors
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler airflow dags list-import-errors
```

### Trigger a DAG Run

**Option 1: UI**  
Go to http://localhost:8080 → DAGs → `banking_delta_daily` → Trigger DAG → optionally set config `{"publish_full": true}` for full republish.

**Option 2: CLI**
```bash
# Normal daily run
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow dags trigger banking_delta_daily

# With config (full republish)
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow dags trigger banking_delta_daily --conf '{"publish_full": true}'

# Trigger watchdog DAG manually
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow dags trigger banking_watchdog
```

**Option 3: REST API**
```bash
curl -X POST http://localhost:8080/api/v1/dags/banking_delta_daily/dagRuns \
  -H "Content-Type: application/json" \
  -u admin:admin \
  -d '{"conf": {"publish_full": true}}'
```

### Pause / Unpause DAG

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow dags pause banking_delta_daily

docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow dags unpause banking_delta_daily
```

### Backfill / Re-run Historical Dates

```bash
# Re-run for specific date range
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow dags backfill banking_delta_daily \
  --start-date 2026-01-01 --end-date 2026-01-31 \
  --reset-dagruns
```

---

## Monitoring & Debugging

### Task Instance Status

```bash
# List recent runs
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow dags list-runs -d banking_delta_daily --limit 10

# Show task states for a specific run
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow tasks states-for-dag-run banking_delta_daily 2026-10-21T02:00:00+00:00

# Clear failed tasks for re-run
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow tasks clear banking_delta_daily \
  --task-regex ".*" \
  --dag-run-id scheduled__2026-10-21T02:00:00+00:00 \
  --yes
```

### Inspect Worker / Scheduler

```bash
# Shell into worker
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-worker bash

# Shell into scheduler
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler bash

# Check Celery queue
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-worker \
  celery -A airflow.providers.celery.executors.celery_executor.app inspect active
```

### Database Access

```bash
# Connect to Airflow metadata DB
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-db \
  psql -U airflow -d airflow_db

# Query recent DAG runs
# SELECT dag_id, execution_date, state, start_date, end_date FROM dag_run ORDER BY execution_date DESC LIMIT 20;
```

### Preflight Checks (No Data Touched)

```bash
# Validate DAG parsing, connections, variables
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-worker \
  python -m banking_airflow.preflight

# Test email notification
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-worker \
  python -m banking_airflow.notify --test

# Check DAG import errors
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow dags list-import-errors
```

---

## Configuration Reference

### Key Environment Variables (`.env.airflow`)

| Category | Variables |
|----------|-----------|
| **Airflow Core** | `AIRFLOW__CORE__FERNET_KEY`, `AIRFLOW__API_AUTH__JWT_SECRET`, `AIRFLOW__API__SECRET_KEY` |
| **Metadata DB** | `AIRFLOW_DB_USER`, `AIRFLOW_DB_PASSWORD`, `AIRFLOW_DB_NAME` |
| **Celery/Redis** | `REDIS_PASSWORD`, `WORKER_CONCURRENCY` |
| **Admin User** | `AIRFLOW_ADMIN_USERNAME`, `AIRFLOW_ADMIN_PASSWORD`, `AIRFLOW_ADMIN_EMAIL` |
| **Schedule** | `BANKING_DAG_SCHEDULE` (cron), `TIMEZONE` |
| **Warehouse** | `PG_HOST`, `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASS` |
| **Sources** | `MYSQL_*`, `MONGO_URI`, `DATABRICKS_*` |
| **Spark** | `SPARK_DRIVER_MEMORY`, `EXTRACT_SPARK_DRIVER_MEMORY`, `SPARK_UI_ENABLED` |
| **Reporting** | `REPORT_ENABLED`, `REPORT_OUTPUT_DIR`, `REPORT_RETENTION_DAYS` |
| **Alerts** | `SMTP_*`, `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`, `ALERT_ON_TASK_FAILURE` |

### Volumes

| Volume | Purpose |
|--------|---------|
| `airflow_db_data` | Airflow metadata DB (Postgres) |
| `spark_cache` | Spark `.spark/` cache (jars, ivy) — persists across restarts |
| `report_output` | Generated PDF reports |

---

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow logs airflow-init

# Common causes:
# - .env.airflow missing or has placeholder values
# - Port 8080 already in use
# - Docker Desktop VM out of memory (increase to 8GB+)
# - Host DBs not reachable from container (use host.docker.internal)
```

### DAG Not Appearing

```bash
# Check import errors
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow dags list-import-errors

# Verify DAG file is mounted
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  ls -la /opt/airflow/dags/
```

### Task Failures

```bash
# View task logs
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow exec airflow-scheduler \
  airflow tasks logs banking_delta_daily extract_mysql 2026-10-21T02:00:00+00:00

# Or via UI: Graph View → click task → Log
```

### Reset Everything (Nuclear Option)

```bash
# WARNING: Deletes all metadata, history, reports, Spark cache
docker compose -f docker-compose.yml -f docker-compose.dev.yml --env-file .env.airflow down -v
docker volume prune -f
# Then restart from "Build and Start"
```

---

## Production Notes

- Use `docker-compose.yml` only (no `.dev.yml`)
- Set `AIRFLOW_IMAGE_TAG` to a semantic version (e.g., `v1.2.3`)
- Store secrets in a secret manager, not `.env.airflow`
- Enable `AIRFLOW__API__EXPOSE_CONFIG=false`
- Run behind a reverse proxy with TLS
- Monitor `airflow-scheduler` and `airflow-worker` health endpoints
- Backup `airflow_db_data` volume regularly

---

## Related Files

- `AIRFLOW_AGENT_GUIDE.md` — Deep dive for agents (runbook, troubleshooting §14)
- `docker-compose.yml` — Base service definitions
- `docker-compose.dev.yml` — Development overrides
- `Dockerfile` — Airflow image build
- `.env.airflow.example` — Template with all required variables