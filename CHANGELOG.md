# Changelog

All notable changes to Banking-Delta-Lakehouse are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions match `pyproject.toml`; releases are cut by pushing a `vX.Y.Z` tag that
the `release` workflow verifies before publishing.

## [Unreleased]

### Added

- **`main.py` step 1 — `preflight`.** New `src/utils/preflight.py` probes PostgreSQL,
  MySQL, MongoDB and Databricks (SELECT 1 / ping) with capped exponential backoff and
  equal jitter before any extract runs. Credential failures are never retried (they
  fail in seconds as `PreflightError`); anything else retries until its budget runs
  out and then stops the run with the last error in the summary table. Budgets:
  `PREFLIGHT_TIMEOUT` (60s) and `PREFLIGHT_DATABRICKS_TIMEOUT` (300s), each with
  `PREFLIGHT_BASE` / `PREFLIGHT_CAP` overrides for tests. The pipeline is now 10 steps.
- **"About the data" disclosure.** README and `docs/INSIGHTS.md` now describe how the
  shipped `data/raw` snapshots are produced, mark the origin as unverified
  (`TODO(owner)`), and state that the insight figures (fraud rate, late-payment rate,
  concentration) are properties of this dataset, not real-world benchmarks.
- **Architecture decision log.** `docs/DECISIONS.md` records nine decisions (stored
  procedures vs dbt, four Postgres layers, PySpark for extraction, watermarks and late
  arrivals, Airflow, DQ gates, Delta publish, read-only consumers, landing contracts)
  with alternatives, rationale and trade-offs; linked from the README docs table.
- **Unit coverage raised from 43.7% to 91.0%.** The unit tier grew from 266 to 732
  tests, covering the audit writer, Spark I/O helpers, extract runner, all four DQ
  runners, engine/session, script CLIs, Airflow preflight/callbacks/audit reader and
  the report collector; `make cov` and `make ci` stay green.
- **Insight segment views.** `docs/INSIGHTS.md` now adds one segmentation query per
  domain (income band, loan size, card tier, region, branch region, issue type) with
  the measured result and a "So what" line; the six detail docs link their query.

- **Business insights docs.** `docs/INSIGHTS.md` index plus six per-domain write-ups under `docs/insights/` with reproducible SQL in `docs/insights/queries/` and charts in `assets/insights/`.
- **Environment setup automation.** `scripts/setup_env.sh` to initialize `.env` files from `.example` templates.
- **Log management automation.** `scripts/monitor_logs.sh` to monitor and cleanup old/large log files.
- **Task runner integration.** Added `setup-env` and `monitor-logs` targets to `Makefile` and `tasks.bat`.

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

- **Analytics check #7 staleness now compares layers, not the wall clock.**
  `tests/data-quality/analytics/00_lp_check_upstream_freshness.sql` (new) defines
  `audit.dq_analytics_upstream_lag()`, and `01_lp_check_metadata_col.sql` calls it
  instead of its own 7-day `now()` window: a table fails only when its
  `max(row_updated_at)` is more than **1 hour** behind the staging table it is built
  from (mapping lives in the function), and 30 days without rows
  is a `RAISE WARNING`, never a failure. The helper is a `00_` file, so the runner
  applies it before `01` on a full run — `--only 01` on its own uses whatever
  version is already in the database.
- **Docs and skills follow the 10-step order.** `ARCHITECTURE.md`, `README.md`,
  `docs/{PIPELINE,PROBLEM,QUICKSTART,RUNBOOK,TESTING,DATA-QUALITY}.md`,
  `.claude/docs/interfaces.md` and the `operate-the-pipeline` /
  `debugging-pipeline` skills list `preflight` first; `docs/DATA-QUALITY.md` also
  documents the DDL-only `00_` helper contract.
- Data-quality procedures are documented per file and grouped under per-layer
  master gate procedures.
- `make sql-lint` is green: added an explicit `.sqlfluff` baseline (dialect,
  capitalisation policy, `max_line_length`) and `.sqlfluffignore` for the raw
  exploration probes, so `make ci` and `tasks.bat ci` pass end to end.
- **`main.py` — `run_load()` deploys every `sp_load_*` procedure via `psql -f`**
  before calling `sp_load_all()`, so edits to `sql/*/0N_*.sql` files actually take
  effect. Replaced the fragile Python SQL-statement splitter with native `psql`
  deployment (the way the files are written to be run), fixing `syntax error at
  or near "ORDER"` on PL/pgSQL `$$`-quoted bodies.
- **`src/jobs/publish_marts.py` — publish now does a full overwrite**
  (`INSERT OVERWRITE`) instead of incremental MERGE on a watermark, because PG marts
  are rebuilt wholesale each run (`DROP + CTAS`). Avoids re-reading every row and
  never deleting rows that fell out of the mart.
- **`sql/analytics/{03_dim_branch,05_dim_card,09_dim_txn_profile}.sql` — heartbeat**
  on no-change daily runs: when `inserted + updated = 0`, touch one non-Unknown row
  so `row_updated_at` advances and the metadata staleness gate does not false-positive.
- **README & insights polish:** clarified customer concentration question, labeled
  fraud amount, reworded loan payment frequency, added engineering at a glance table,
  removed duplicate tech-stack line, fixed footer links and logo alignment.

### Fixed

- **Analytics `01_lp_check_metadata_col.sql` false-positive staleness.** The 2026-11-05
  run (`audit.dq_run` 3729) failed with 5 violations — `dim_loan`,
  `fact_card_transactions`, `fact_loan_payments`, `fact_support_tickets` and
  `fact_transactions` "stale, limit 7 days" — although staging, their upstream, was
  *older* still (2026-10-20 vs 2026-10-28). Freshness is now the upstream lag rule
  above, so a quiet source no longer fails the gate while a real load gap still does
  (proved by inserting a newer staging row: the check fails, and passes again after
  the row is removed). The heartbeat workaround above is no longer load-bearing for
  this check and is left in place.
- **Pipeline failure at `analytics-tests`**: `01_lp_check_metadata_col.sql` check #7
  flagged `dim_branch`, `dim_card` and `dim_txn_profile` as stale (`max(row_updated_at)`
  = 2026-10-18, past the 7-day limit). Root cause: `analytics-load` found no source
  changes, so no `UPDATE` fired the `set_updated_at('row_updated_at')` trigger and
  `row_updated_at` stayed stuck. The heartbeat fix advances it on no-change runs;
  the 7-day rule stood at that point and is now superseded by the upstream-lag rule
  above.

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
