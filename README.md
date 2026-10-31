<p align="center">
  <img src="assets/logo/logo4.png" alt="Banking-Delta-Lakehouse" width="420">
</p>

<h1 align="center">Banking Delta Lakehouse</h1>

<p align="center">
  Banking-Delta-Lakehouse is a daily banking lakehouse pipeline that ingests data from MySQL, MongoDB, and Databricks using PySpark, transforms it in PostgreSQL through four layers (raw → staging → analytics → marts), and publishes curated Delta tables to Databricks. Apache Airflow        orchestrates the pipeline, PostgreSQL stored procedures handle transformations, and automated data-quality gates, audit logging, and a read-only Streamlit dashboard support reliable data delivery.
</p>

## Tech stack

<p align="center">
  <img alt="Python 3.13" src="https://img.shields.io/badge/Python-3.13-3776AB?logo=python&logoColor=white" />
  <img alt="Ubuntu" src="https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white" />
  <img alt="PySpark 4.1" src="https://img.shields.io/badge/PySpark-4.1-E25A1C?logo=apachespark&logoColor=white" />
  <img alt="PostgreSQL" src="https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white" />
  <img alt="MongoDB" src="https://img.shields.io/badge/MongoDB-7-47A248?logo=mongodb&logoColor=white" />
  <img alt="Airflow" src="https://img.shields.io/badge/Airflow-3.3.2-017CEE?logo=apacheairflow&logoColor=white" />
  <img alt="Docker" src="https://img.shields.io/badge/Docker-27-2496ED?logo=docker&logoColor=white" />
  <img alt="Medallion" src="https://img.shields.io/badge/Medallion-Lakehouse-8B5CF6" />
  <img alt="Streamlit" src="https://img.shields.io/badge/Streamlit-1.62-FF4B4B?logo=streamlit&logoColor=white" />
  <img alt="Plotly" src="https://img.shields.io/badge/Plotly-7-3F4F75?logo=plotly&logoColor=white" />
  <img alt="CI" src="https://github.com/Nitinx12/Banking-Delta-Lakehouse/actions/workflows/ci.yml/badge.svg" />
  <img alt="Last Release" src="https://img.shields.io/github/v/release/Nitinx12/Banking-Delta-Lakehouse?label=Release" />
  <img alt="Ruff" src="https://img.shields.io/badge/Ruff-0.12.0-000000?logo=ruff" />
  <img alt="pre-commit" src="https://img.shields.io/badge/pre--commit-FAB005?logo=precommit" />
  <img alt="License MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg" />
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

## Live Dashboard

<p align="center">
  <a href="https://walmartdbt-b3fdfqwyky3ghzr5syyxtu.streamlit.app/"><b>Live Demo</b></a> &mdash; interactive dashboard on the <code>marts</code> schema &middot; <a href="dashboard/README.md">docs</a>
</p>

<p align="center">
  <a href="https://walmartdbt-b3fdfqwyky3ghzr5syyxtu.streamlit.app/">
    <img src="assets/images/dashboard_image2.png" width="90%" alt="Walmart Sales Dashboard — gold schema" style="border-radius:12px; border:1px solid #e2e8f0; box-shadow: 0 8px 30px rgba(15,23,42,0.12);" />
  </a>
</p>

</p>

<p align="center">
  <sub><code>Python</code> · <code>PySpark</code> · <code>R</code> · <code>PostgreSQL</code> · <code>MongoDB</code> · <code>Apache Airflow</code> · <code>Docker</code> · <code>MySQL</code> · <code>Databricks</code> · <code>Streamlit</code> · <code>Plotly</code> · <code>uv</code> · <code>Ruff</code> · <code>Latex</code></sub>
</p>

## Quick start

For a step-by-step guide see [docs/QUICKSTART.md](docs/QUICKSTART.md).

```bash
make install     # runtime + dev dependencies (uv)
make hooks       # enable the repo git hooks
make ci          # local gate: lint + contracts + sql-lint + coverage + smoke
make daily       # run the whole pipeline
```

## Common commands

```bash
# Full gated pipeline (writes to warehouse + Databricks)
make daily                      # or: python main.py
make run-jobs                   # extracts only: mongo -> databricks -> mysql

# Data quality gates
make dq                         # raw -> staging -> analytics -> marts
make dq-raw                     # single layer

# One layer at a time
make staging && make dq-staging
make analytics && make dq-analytics
make marts && make dq-marts
make publish                    # publish marts to Databricks Delta

# Tests
make ci                         # lint + contracts + sql-lint + coverage + smoke
make test                       # unit + smoke
make unit / make smoke

# Airflow stack
make up                         # docker compose up -d
make down

# Dashboard (Streamlit, read-only against Databricks marts)
cd dashboard && streamlit run app.py

# Reports
make report-fixture             # render all fixtures, no TeX, no DB
make report                     # daily PDF against the warehouse in .env
```
On Windows use `tasks.bat <target>` instead of `make <target>`; the two are
kept in sync by `tests/smoke/test_make_parity.py`.

## Documentation

| Doc | What it covers |
| --- | --- |
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | Step-by-step guide to running the project locally. |
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
