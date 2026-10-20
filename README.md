<p align="center">
  <img src="assets/logo/logo4.png" alt="Banking-Delta" width="420">
</p>

# Banking-Delta

Daily lakehouse pipeline: MySQL, MongoDB and Databricks `public` → PySpark →
PostgreSQL (`landing → staging → core → mart`) → Databricks `core`/`mart`.
Airflow orchestrates, stored procedures transform, Great Expectations validates.

## Tech stack

<p align="center">
  <img alt="Python 3.13" src="https://img.shields.io/badge/Python-3.13-3776AB?logo=python&logoColor=white" />
  <img alt="Ubuntu" src="https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white" />
  <img alt="PySpark 4.1" src="https://img.shields.io/badge/PySpark-4.1-E25A1C?logo=apachespark&logoColor=white" />
  <img alt="PostgreSQL" src="https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white" />
  <img alt="MongoDB" src="https://img.shields.io/badge/MongoDB-7-47A248?logo=mongodb&logoColor=white" />
  <img alt="Airflow" src="https://img.shields.io/badge/Airflow-3.3.2-017CEE?logo=apacheairflow&logoColor=white" />
  <img alt="dbt" src="https://img.shields.io/badge/dbt-1.8-FF694B?logo=dbt&logoColor=white" />
  <img alt="Docker" src="https://img.shields.io/badge/Docker-27-2496ED?logo=docker&logoColor=white" />
  <img alt="Medallion" src="https://img.shields.io/badge/Medallion-Lakehouse-8B5CF6" />
  <img alt="Streamlit" src="https://img.shields.io/badge/Streamlit-1.62-FF4B4B?logo=streamlit&logoColor=white" />
  <img alt="Plotly" src="https://img.shields.io/badge/Plotly-7-3F4F75?logo=plotly&logoColor=white" />
  <img alt="CI" src="https://github.com/Nitinx12/Banking-Delta-Lakehouse/actions/workflows/ci.yml/badge.svg" />
  <img alt="Last Release" src="https://img.shields.io/github/v/release/Nitinx12/Banking-Delta-Lakehouse?label=Release" />
  <img alt="Ruff" src="https://img.shields.io/badge/Ruff-0.12.0-000000?logo=ruff" />
  <img alt="pre-commit" src="https://img.shields.io/badge/pre--commit-FAB005?logo=precommit" />
  <img alt="License MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg" />
  <img alt="Discord" src="https://img.shields.io/badge/Discord-Join-5865F2?logo=discord" />
  <img alt="LinkedIn" src="https://img.shields.io/badge/LinkedIn-Connect-0A66C2?logo=linkedin" />
  <img alt="Twitter" src="https://img.shields.io/badge/Twitter-Follow-1DA1F2?logo=x" />
  <img alt="Awesome Python" src="https://awesome-python.com/badge.svg" />
  <img alt="Live Demo" src="https://img.shields.io/badge/Live%20Demo-Open-2ea44f" />
  <img alt="GitHub" src="https://img.shields.io/badge/GitHub-Repo-181717?logo=github" />
</p>

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

---

<p align="center">
  <strong>Built with ❤️ for the data community</strong> · MIT License ·
  <a href="https://github.com/Nitinx12/Banking-Delta-Lakehouse/issues">Report a bug</a> ·
  <a href="https://github.com/Nitinx12/Banking-Delta-Lakehouse">⭐ Star on GitHub</a>
</p>

<p align="center">
  <a href="#">💬 Discord chat</a> ·
  <a href="#">💼 LinkedIn</a> ·
  <a href="#">🐦 Twitter</a>
</p>
