# Changelog

All notable changes to Banking-Delta are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions match `pyproject.toml`; releases are cut by pushing a `vX.Y.Z` tag that
the `release` workflow verifies before publishing.

## [Unreleased]

### Added

- **Data contracts.** Validated source → `raw` landing contracts
  (`contracts/`): a JSON Schema (`source-table.schema.json`), a registry mirroring
  `audit.source_tables`, per-table contracts for the ten sources, a template and a
  `python -m contracts.validate` checker wired into `make contracts`, the pre-commit
  hook and `tasks.bat`.
- **Architecture blueprint.** `ARCHITECTURE.md` — the repository blueprint with
  mermaid diagrams and the standard colour legend covering sources, orchestration,
  the PostgreSQL layers, Databricks publish, gates, CI/CD and deployment.
- **CI/CD.** GitHub Actions pipeline (`.github/workflows/`): `ci` (lint, contracts,
  sql-lint, unit, smoke, with a Windows runner and a required `gate`), `leaks`
  (gitleaks over full history), `codeql` (Python), `nightly` (sql-smoke and
  integration on a disposable Postgres) and `release` (tag-triggered, verifies the
  commit and cross-checks the tag against `pyproject.toml`).
- **Repo automation.** `dependabot.yml`, CODEOWNERS, PR template, issue templates
  and `.gitleaks.toml`.
- **Windows parity.** `tasks.bat` mirrors every `Makefile` target and is kept in
  sync by `tests/smoke/test_make_parity.py`.
- **Local hooks.** Portable `.githooks/{pre-commit,pre-push,commit-msg}`.
- **Tests.** Hermetic smoke and unit suites (`tests/unit`, `tests/smoke`) plus
  shared fixtures in `tests/conftest.py`.
- **Docs.** `docs/{PIPELINE,CONTRACTS,DATA-QUALITY,AUDIT,AIRFLOW,TESTING,CI-CD,
  GITWORKFLOWS,DEPLOYMENT,RUNBOOK,TROUBLESHOOTING}.md` with a README docs index,
  plus `CONTRIBUTING.md` and `SECURITY.md`.

### Changed

- Data-quality procedures are documented per file and grouped under per-layer
  master gate procedures.

### Removed

- `repo_detailes.md` (superseded by `ARCHITECTURE.md` and `docs/`) and all of its
  references.

## [0.1.0] - 2026-10-20

First working end-to-end pipeline: three source systems landed into PostgreSQL with
PySpark, transformed through `raw → staging → analytics → marts` by stored
procedures, gated by per-layer data-quality suites, and published to Databricks
Delta where a read-only Streamlit dashboard serves them.

### Added

- **Project scaffold.** `pyproject.toml` with pinned Python, ruff and pytest
  markers, the `Makefile`, logger and Spark connector-jar caching.
- **Extraction framework.** `src/utils/{session,connection,engine,audit,spark_io}.py`,
  the shared `extract_runner.py`, and one extractor per source
  (`extract_mysql.py`, `extract_mongo.py`, `extract_databricks.py`). Incremental
  loads carry watermarks; Mongo types are cast and landing metadata
  (`_batch_id`, `_loaded_at`) is enforced.
- **Source registry.** Mongo, Databricks and MySQL source tables registered in
  `audit.source_tables`; `scripts/run_jobs.py` runs the extracts in order.
- **Audit schema.** `audit.*` for pipeline runs, table runs, errors, watermarks and
  data-quality run history, with an idempotent SCD1 load pattern.
- **Data quality.** Ten checks for `raw`, ten for `staging`, thirteen for
  `analytics` and eleven for `marts`, each with a master gate procedure and a runner
  that exits non-zero on failure; staging load procedures and master orchestration.
- **Warehouse layers.** `staging`, `analytics` (`dim_*` / `fact_*`) and `marts`
  (`mart_*`) schemas built by `sp_load_*` stored procedures.
- **Publish to Databricks.** `src/jobs/publish_marts.py` reads PostgreSQL marts,
  writes Parquet with pyarrow into a Unity Catalog volume and MERGEs into Delta.
- **Orchestration.** Airflow 3.3.2 CeleryExecutor stack with `banking_delta_daily`
  and `banking_watchdog` DAGs, notify/summary modules and preflight checks
  (`airflow/`).
- **Dashboard.** Read-only Streamlit executive dashboard served from Databricks SQL
  (`dashboard/`).
- **Runbook docs.** `main.py` (`--list`, `--from`, `--only`, `--keep-going`) and the
  raw exploration scripts under `sql/`.

[Unreleased]: https://github.com/Nitinx12/Banking-Delta-Lakehouse/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Nitinx12/Banking-Delta-Lakehouse/releases/tag/v0.1.0
