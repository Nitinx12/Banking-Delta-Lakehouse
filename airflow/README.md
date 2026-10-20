# Banking-Delta Airflow

Orchestration layer for the Banking-Delta daily pipeline. Airflow only triggers
existing entry points (`main.py`, `scripts/run_jobs.py`, `src/jobs/publish_marts.py`);
no pipeline logic lives here. Full rules: [`AIRFLOW_AGENT_GUIDE.md`](AIRFLOW_AGENT_GUIDE.md).

## Start

```bash
cd airflow
cp .env.airflow.example .env.airflow && chmod 600 .env.airflow   # fill every value
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"  # FERNET_KEY
python -c "import secrets; print(secrets.token_urlsafe(64))"     # JWT_SECRET, SECRET_KEY

export AIRFLOW_IMAGE_TAG=$(git rev-parse --short HEAD) GIT_SHA=$AIRFLOW_IMAGE_TAG
docker compose --env-file .env.airflow build
docker compose --env-file .env.airflow up airflow-init           # must exit 0
docker compose --env-file .env.airflow up -d
```

UI: `http://127.0.0.1:8080` (login from `.env.airflow`). `banking_delta_daily` is
created paused; un-pause it deliberately.

## Stop

```bash
docker compose --env-file .env.airflow down          # keep data
docker compose --env-file .env.airflow down -v       # also drop metadata + logs
```

## Trigger a run

From the UI (banking_delta_daily → Trigger, set `publish_full` for a `--full`
republish), or:

```bash
docker compose --env-file .env.airflow exec airflow-scheduler \
  airflow dags trigger banking_delta_daily
```

## Where the email goes

Every run emails a summary to `ALERT_EMAIL_TO` (sender `ALERT_EMAIL_FROM`),
subject `[SUCCESS|WARNING|FAILED] Banking-Delta daily pipeline — <date>`. Final
task failures also send an immediate `[FAILED]` mail. The `banking_watchdog` DAG
mails `[MISSED]`/`[STUCK]` if the daily run stops succeeding.

## Smoke tests (no data touched)

```bash
docker compose exec airflow-worker /opt/banking-venv/bin/python -m banking_airflow.preflight
docker compose exec airflow-worker python -m banking_airflow.notify --test
docker compose exec airflow-scheduler airflow dags list-import-errors
```

## Who to call

- Pipeline failures (extract/load/DQ/publish): data-platform owner of the failing layer.
- Airflow itself (scheduler/worker/metadata): platform team.
- Warehouse or credentials: DBA / source-system owner.

Runbook and troubleshooting: `AIRFLOW_AGENT_GUIDE.md` §14.
