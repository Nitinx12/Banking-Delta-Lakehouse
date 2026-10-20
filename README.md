<p align="center">
  <img src="assets/logo4.png" alt="Banking-Delta" width="420">
</p>

# Banking-Delta

Daily lakehouse pipeline: MySQL, MongoDB and Databricks `public` → PySpark →
PostgreSQL (`landing → staging → core → mart`) → Databricks `core`/`mart`.
Airflow orchestrates, stored procedures transform, Great Expectations validates.

## Pipeline at a glance

```mermaid
flowchart LR
    subgraph SRC["Source systems (read-only)"]
        MYSQL[("MySQL<br/>5 tables · full")]
        MONGO[("MongoDB<br/>2 collections · incr")]
        DBXPUB[("Databricks public<br/>3 tables · incr")]
    end

    subgraph ORCH["Orchestration"]
        AF["Airflow 3.3.2<br/>banking_delta_daily · 02:00 IST"]
        MAIN["main.py<br/>9 gated steps"]
        RJ["run_jobs.py<br/>mongo → databricks → mysql"]
    end

    subgraph PG["PostgreSQL · banking_delta"]
        RAW[("raw<br/>landed as-is")]
        STG[("staging<br/>typed · deduped")]
        ANA[("analytics<br/>dim_* / fact_*")]
        MRT[("marts<br/>mart_* business")]
    end

    DELTA[("Databricks Delta<br/>marts.mart_*")]
    DASH["Streamlit<br/>read-only"]
    AUD["audit · DQ gates"]

    AF -->|BashOperator| MAIN
    MAIN -->|subprocess| RJ
    MYSQL -->|Spark JDBC| RJ
    MONGO -->|mongo connector| RJ
    DBXPUB -->|SQL connector| RJ
    RJ -->|_stg_ then raw| RAW
    MAIN -->|CALL sp_load_all| STG --> ANA --> MRT
    MAIN -->|publish_marts.py| DELTA
    DELTA -->|SELECT| DASH
    RAW -.-> AUD
    STG -.-> AUD
    ANA -.-> AUD
    MRT -.-> AUD

    classDef src fill:#dbeafe,stroke:#1d4ed8,color:#1e3a8a,stroke-width:2px
    classDef orch fill:#ede9fe,stroke:#6d28d9,color:#4c1d95,stroke-width:2px
    classDef raw fill:#ffedd5,stroke:#c2410c,color:#7c2d12,stroke-width:2px
    classDef staging fill:#cffafe,stroke:#0e7490,color:#164e63,stroke-width:2px
    classDef analytics fill:#dcfce7,stroke:#15803d,color:#14532d,stroke-width:2px
    classDef marts fill:#fce7f3,stroke:#be185d,color:#831843,stroke-width:2px
    classDef delta fill:#fef9c3,stroke:#a16207,color:#713f12,stroke-width:2px
    classDef audit fill:#f1f5f9,stroke:#475569,color:#1e293b,stroke-width:2px
    classDef ui fill:#e0e7ff,stroke:#4338ca,color:#312e81,stroke-width:2px

    class MYSQL,MONGO,DBXPUB src
    class AF,MAIN,RJ orch
    class RAW raw
    class STG staging
    class ANA analytics
    class MRT marts
    class DELTA delta
    class AUD audit
    class DASH ui
```

Colour legend (same as `ARCHITECTURE.md`): blue = sources, violet = orchestration,
orange = `raw`, cyan = `staging`, green = `analytics`, pink = `marts`,
yellow = Databricks Delta, slate = audit / DQ, indigo = read-only consumers.

## Quick start

```bash
make install     # runtime + dev dependencies (uv)
make hooks       # enable the repo git hooks
make ci          # local gate: lint + contracts + sql-lint + coverage + smoke
make daily       # run the whole pipeline
```

On Windows use `tasks.bat <target>` instead of `make <target>`; the two are
kept in sync by `tests/smoke/test_make_parity.py`.

## Documentation

| Doc | What it covers |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The blueprint: layers, flow, gates and contracts. |
| [docs/PIPELINE.md](docs/PIPELINE.md) | The daily pipeline end to end. |
| [docs/CONTRACTS.md](docs/CONTRACTS.md) | Data contracts: source → `raw` landing. |
| [docs/DATA-QUALITY.md](docs/DATA-QUALITY.md) | DQ contract per layer and how it gates publish. |
| [docs/AUDIT.md](docs/AUDIT.md) | Audit tables, watermarks and run lineage. |
| [docs/AIRFLOW.md](docs/AIRFLOW.md) | DAGs, schedule and task gating. |
| [docs/TESTING.md](docs/TESTING.md) | Test markers, layouts and how to run them. |
| [docs/CI-CD.md](docs/CI-CD.md) | Workflows, required checks and release flow. |
| [docs/GITWORKFLOWS.md](docs/GITWORKFLOWS.md) | Branching, commits and hooks. |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Environments and rollout. |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Operating the pipeline day to day. |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common failures and fixes. |

Contributing and security policies live in [CONTRIBUTING.md](CONTRIBUTING.md)
and [SECURITY.md](SECURITY.md).
