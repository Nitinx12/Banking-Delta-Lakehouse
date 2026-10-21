# Airflow — Banking-Delta-Lakehouse

Airflow 3.3.2 (CeleryExecutor) in Docker Compose orchestrates the daily run. It contains
**no pipeline logic**: every task calls the same scripts and SQL as `python main.py`
(`docs/PIPELINE.md`). Two DAGs live in `airflow/dags/`.

Colour legend: `docs/PIPELINE.md` (violet = Airflow services, indigo = pipeline steps run
inside the worker, slate = audit, red = gates/failures, yellow = mail).

## Compose stack

Image (`airflow/Dockerfile`, build context = repo root): `apache/airflow` + JRE +
project venv (`uv sync --frozen`) + `main.py`, `src/`, `scripts/`, `sql/`,
`tests/data-quality/`, `airflow/{dags,include,scripts}`. The Dockerfile-specific
`Dockerfile.dockerignore` keeps `.env`, `.venv`, `.spark` and keys out of the context.

```mermaid
flowchart TB
    subgraph STACK["banking-delta-airflow (CeleryExecutor)"]
        DB[("airflow-db<br/>postgres:16-alpine")]
        RD[("airflow-redis<br/>redis:7-alpine")]
        INIT["airflow-init<br/>db migrate + admin + pools"]
        API["airflow-apiserver<br/>127.0.0.1:8080"]
        SCH["airflow-scheduler"]
        DP["airflow-dag-processor"]
        TRG["airflow-triggerer"]
        WRK["airflow-worker<br/>Celery, mem_limit 6g<br/>volume: spark_cache"]
    end

    subgraph PIPE["Pipeline containers run inside airflow-worker"]
        PRE["preflight"]
        EX["run_jobs.py x3"]
        LD["main.py load/test steps"]
        PB["publish_marts.py"]
        FIN["finalize_audit"]
        SUM["send_pipeline_summary"]
    end

    DB --> INIT
    RD --> INIT
    INIT --> API
    INIT --> SCH
    INIT --> DP
    INIT --> TRG
    INIT --> WRK
    SCH -->|queue| WRK
    WRK --> PRE --> EX --> LD --> PB --> FIN --> SUM

    classDef infra fill:#f1f5f9,stroke:#475569,color:#1e293b,stroke-width:2px
    classDef af fill:#ede9fe,stroke:#6d28d9,color:#4c1d95,stroke-width:2px
    classDef pipe fill:#e0e7ff,stroke:#4338ca,color:#312e81,stroke-width:2px
    class DB,RD infra
    class INIT,API,SCH,DP,TRG,WRK af
    class PRE,EX,LD,PB,FIN,SUM pipe
```

`airflow-init` runs `airflow db migrate`, creates the admin user and pool `spark_jvm`
(3 slots — the extracts and publish share it). The worker mounts `spark_cache` at
`.spark` so Ivy jars survive restarts.

### Environment split (easy to get wrong)

| File | Loaded by | Holds |
|---|---|---|
| `airflow/.env` | Compose interpolation | `AIRFLOW_VERSION`, `PYTHON_VERSION`, image tag, DB/Redis settings |
| `airflow/.env.airflow` | every container (`env_file:`) | real pipeline secrets: `PG_*`, `MYSQL_*`, `MONGO_*`, `DATABRICKS_*`, `SMTP_*` |

Copy `.env.airflow.example` → `.env.airflow` and fill it in. Missing `AIRFLOW_VERSION` in
`.env` makes `docker compose config` fail immediately. `docker-compose.dev.yml` bind-mounts
code, sets `DAGS_ARE_PAUSED_AT_CREATION=false` and adds `host.docker.internal` so
containers can reach services on the host.

```bash
cd airflow
cp .env.airflow.example .env.airflow          # fill secrets
docker compose --env-file .env.airflow up airflow-init   # must exit 0
docker compose --env-file .env.airflow up -d
# UI: http://127.0.0.1:8080 (login from .env.airflow)
```

## DAG `banking_delta_daily`

`schedule=0 2 * * *` Asia/Kolkata (`BANKING_DAG_SCHEDULE`), `catchup=False`,
`max_active_runs=1`, `max_active_tasks=4`, `dagrun_timeout=5h`, param `publish_full`
(default false). Created **paused** — un-pause deliberately.

```mermaid
flowchart LR
    PRE["preflight<br/>retries=3 · 10m"]
    subgraph EXT["extracts · pool spark_jvm · retries=2 · 2h"]
        EM["extract_mongo<br/>weight 30"]
        ED["extract_databricks<br/>weight 20"]
        EX["extract_mysql<br/>weight 10"]
    end
    RT["raw_tests"]
    SL["staging_load"]
    ST["staging_tests"]
    AL["analytics_load"]
    AT["analytics_tests"]
    ML["marts_load"]
    MT["marts_tests"]
    PB["publish<br/>pool spark_jvm · retries=2 · 2h"]
    FIN["finalize_audit<br/>all_done"]
    SUM["send_pipeline_summary<br/>all_done · retries=3"]
    GATE["fail_if_any_failed<br/>one_failed · retries=0"]

    PRE --> EM
    PRE --> ED
    PRE --> EX
    EM --> RT
    ED --> RT
    EX --> RT
    RT --> SL --> ST --> AL --> AT --> ML --> MT --> PB
    PB --> FIN --> SUM
    RT -.-> GATE
    SL -.-> GATE
    ST -.-> GATE
    AL -.-> GATE
    AT -.-> GATE
    ML -.-> GATE
    MT -.-> GATE
    PB -.-> GATE
    EM -.-> GATE
    ED -.-> GATE
    EX -.-> GATE
    PRE -.-> GATE

    classDef pre fill:#e0e7ff,stroke:#4338ca,color:#312e81,stroke-width:2px
    classDef raw fill:#ffedd5,stroke:#c2410c,color:#7c2d12,stroke-width:2px
    classDef staging fill:#cffafe,stroke:#0e7490,color:#164e63,stroke-width:2px
    classDef analytics fill:#dcfce7,stroke:#15803d,color:#14532d,stroke-width:2px
    classDef marts fill:#fce7f3,stroke:#be185d,color:#831843,stroke-width:2px
    classDef publish fill:#fef9c3,stroke:#a16207,color:#713f12,stroke-width:2px
    classDef audit fill:#f1f5f9,stroke:#475569,color:#1e293b,stroke-width:2px
    classDef gate fill:#fee2e2,stroke:#b91c1c,color:#7f1d1d,stroke-width:2px

    class PRE pre
    class EM,ED,EX,RT raw
    class SL,ST staging
    class AL,AT analytics
    class ML,MT marts
    class PB publish
    class FIN,SUM audit
    class GATE gate
```

| Task | Command | Retries / timeout | Notes |
|---|---|---|---|
| `preflight` | `python -m banking_airflow.preflight` | 3 / 10m | Java, disk, warehouse, sources, Maven — fails in seconds |
| `extract_mongo` / `extract_databricks` / `extract_mysql` | `scripts/run_jobs.py --sources <src> --dag-id … --dag-run-id …` | 2 / 2h | pool `spark_jvm` |
| `raw_tests` … `marts_tests` | `main.py --only <layer>-tests` | **0** / 30m | DQ gate — a data problem does not fix itself |
| `staging_load` … `marts_load` | `main.py --only <layer>-load` | 1 / 1h | `CALL <schema>.sp_load_all(...)` |
| `publish` | `src/jobs/publish_marts.py … [--full]` | 2 / 2h | `--full` from the `publish_full` param |
| `finalize_audit` | `python -m banking_airflow.finalize_audit` | 1 / 10m | `trigger_rule=all_done` |
| `send_pipeline_summary` | `summary.build_and_send(context)` | 3 / 10m | `trigger_rule=all_done` |
| `fail_if_any_failed` | Python task | 0 | `trigger_rule=one_failed` — makes the run red so Airflow state matches reality |

Design rules: one task per `main.py` step name (UI, mail and `main.py` tell the same
story); `max_active_runs=1` queues duplicate triggers instead of overlapping;
`dagrun_timeout=5h` < watchdog `STUCK_HOURS=5` so a stuck run is detectable.

## DAG `banking_watchdog`

Runs every 3 hours; reads `audit.pipeline_runs` directly (independent of the scheduler)
and stays **silent when healthy**.

```mermaid
flowchart TB
    TICK(["every 3 hours"]) --> CONN{"warehouse<br/>reachable?"}
    CONN -->|no| ERR["[WATCHDOG-ERROR]<br/>pipeline status unknown"]
    CONN -->|yes| LAST["latest SUCCESS ended_at"]
    LAST --> AGE{"older than<br/>WATCHDOG_MAX_AGE_HOURS=30?"}
    AGE -->|yes| MISSED["[MISSED]<br/>no success in N hours"]
    AGE -->|no| RUN["latest RUNNING/PARTIAL started_at"]
    RUN --> STUCK{"older than<br/>WATCHDOG_STUCK_HOURS=5?"}
    STUCK -->|yes| STUCKMAIL["[STUCK]<br/>run stuck for N hours"]
    STUCK -->|no| SILENT["stay silent (healthy)"]

    classDef tick fill:#ede9fe,stroke:#6d28d9,color:#4c1d95,stroke-width:2px
    classDef check fill:#e0e7ff,stroke:#4338ca,color:#312e81,stroke-width:2px
    classDef bad fill:#fee2e2,stroke:#b91c1c,color:#7f1d1d,stroke-width:2px
    classDef ok fill:#dcfce7,stroke:#15803d,color:#14532d,stroke-width:2px
    class TICK tick
    class CONN,AGE,STUCK,RUN,LAST check
    class ERR,MISSED,STUCKMAIL bad
    class SILENT ok
```

## Summary, failure and audit flow

```mermaid
flowchart TB
    subgraph RUN["DAG run"]
        T1["preflight → extracts → loads → gates → publish"]
        FIN["finalize_audit<br/>all_done"]
        SUM["send_pipeline_summary<br/>all_done"]
        FAIL["fail_if_any_failed<br/>one_failed"]
        T1 --> FIN
        T1 -.->|any task failed| FAIL
        FIN --> SUM
    end

    subgraph AUD["audit schema (PostgreSQL)"]
        PR[("audit.pipeline_runs")]
        TR[("audit.table_runs")]
        ER[("audit.pipeline_errors")]
        DQ[("audit.data_quality_results")]
        VD[("audit.v_dq_latest")]
    end

    FIN -->|reap RUNNING table_runs<br/>roll up status| PR
    SUM -->|read-only| PR
    SUM -->|read-only| TR
    SUM -->|read-only| ER
    SUM -->|read-only| DQ
    SUM -->|read-only| VD

    T1 -->|extract/publish/DQ write| TR
    T1 -->|extract/publish write| ER
    T1 -->|extract/publish + SQL DQ suites write| DQ

    SUM --> MAIL["SMTP: multipart summary<br/>[SUCCESS|WARNING|FAILED]"]
    FAIL --> CBM["on_failure_callback → notify<br/>[FAILED] dag.task (try n/m)"]

    classDef run fill:#ede9fe,stroke:#6d28d9,color:#4c1d95,stroke-width:2px
    classDef audit fill:#f1f5f9,stroke:#475569,color:#1e293b,stroke-width:2px
    classDef gate fill:#fee2e2,stroke:#b91c1c,color:#7f1d1d,stroke-width:2px
    classDef mail fill:#fef9c3,stroke:#a16207,color:#713f12,stroke-width:2px
    class T1,FIN,SUM run
    class PR,TR,ER,DQ,VD audit
    class FAIL gate
    class MAIL,CBM mail
```

Mail modules: `include/banking_airflow/notify.py` (SMTP, `python -m banking_airflow.notify
--test`), `summary.py` (step table + audit sections; each section degrades independently),
`audit_reader.py` (read-only, parameterised, counts/names/statuses only — never row data),
`redact.py` (URL creds, `password=`/`token=`, PEM, long base64/hex, ≤ 300 chars).

## Operating commands

```bash
# bring up / tear down (from the repo root)
docker compose -f airflow/docker-compose.yml up -d
docker compose -f airflow/docker-compose.yml down        # keep data
docker compose -f airflow/docker-compose.yml down -v     # drop metadata + logs

# trigger
docker compose -f airflow/docker-compose.yml exec airflow-scheduler \
  airflow dags trigger banking_delta_daily
# full republish:
docker compose -f airflow/docker-compose.yml exec airflow-scheduler \
  airflow dags trigger banking_delta_daily --conf '{"publish_full": true}'

# inspect
docker compose -f airflow/docker-compose.yml exec airflow-scheduler airflow dags list-runs -o table
docker compose -f airflow/docker-compose.yml exec airflow-scheduler \
  airflow tasks states-for-dag-run banking_delta_daily "<run_id>"
docker compose -f airflow/docker-compose.yml exec airflow-scheduler \
  airflow tasks logs banking_delta_daily "<run_id>" preflight
docker compose -f airflow/docker-compose.yml exec airflow-scheduler airflow dags list-import-errors

# smoke tests
docker compose -f airflow/docker-compose.yml exec airflow-worker \
  /opt/banking-venv/bin/python -m banking_airflow.preflight
docker compose -f airflow/docker-compose.yml exec airflow-worker \
  python -m banking_airflow.notify --test
```

Day-to-day operations: `docs/RUNBOOK.md`. Problems: `docs/TROUBLESHOOTING.md`.

## Tests

`airflow/tests/` (run by `make unit` / `make smoke`): `test_dag_integrity.py` (DagBag
loads both DAGs; graph, retries, pools, `max_active_runs=1`, `dagrun_timeout < 6h`),
`test_commands.py` (no secrets in command builders, `exec`/`cd`/ctx ids),
`test_no_secrets.py`, `test_notify_render.py` (template redaction),
`test_summary.py` (`decide_status` never SUCCESS on a missing state).
`conftest.py` stubs POSIX-only hooks so tests import on Windows.

## Known issue (open, needs approval to fix)

**False `[FAILED]` summary banner.** `summary.task_states_from_context()` reads
`context["task_states"]`, which Airflow 3 does not provide — every step renders
`NOT_RUN`, so a green run emails `[FAILED]` (and `env=unknown | build=unknown`).
The audit sections in the same mail are correct. Fix: use
`TaskInstance.get_task_states(dag_id=…, run_ids=[run_id])` and pass `env`/`git_sha` from
the DAG. A regression test for this exists as a known gap — see `docs/TESTING.md`.
Do not "fix" it silently.
