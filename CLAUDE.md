# Banking Delta Lakehouse

Rules for AI agents working in this repository.

**`AGENTS.md` is the source of truth.** If this file and `AGENTS.md` disagree, follow
`AGENTS.md`. If either file disagrees with `ARCHITECTURE.md`, the architecture wins.
Report-specific rules live in `docs/REPORTING.md` §3 and §13 and override both files
for report code.

## Project in one line

Daily pipeline: MySQL, MongoDB and Databricks `public` → PySpark → PostgreSQL
(landing → staging → analytics → marts) → Databricks `core`/`marts`. Airflow
orchestrates, stored procedures transform, and SQL DQ suites gate every layer
(`audit.dq_*` procedures in `tests/data-quality/`, 48 checks across four layers).

## Tech stack

- **Languages:** Python 3.13 (PySpark), SQL (PostgreSQL)
- **Orchestration:** Airflow (docker compose under `airflow/`)
- **Storage:** PostgreSQL warehouse → Databricks Delta (`core`/`marts` publish)
- **Validation:** SQL DQ suites (`audit.dq_*`), not Great Expectations
- **Tooling:** ruff, sqlfluff, pytest (+ coverage), uv, GNU Make / `tasks.bat`

## Commands (every target exists in the `Makefile`)

- **Static checks:** `make lint` (ruff check + format), `make contracts`, `make sql-lint`
- **Tests:** `make test` (unit + smoke), `make unit`, `make smoke`, `make cov`
- **Gate:** `make ci` — lint + contracts + sql-lint + coverage + smoke + report fixtures
- **Pipeline:** `make run-jobs` → `make staging` → `make analytics` → `make marts` → `make publish`,
  gated as `make dq-raw|dq-staging|dq-analytics|dq-marts`, or all at once with `make daily`
- **CSV bootstrap (no source access):** `make load-raw-csv` (loads `data/raw/*.csv.gz`),
  `make export-raw-csv` (maintainers refresh the snapshots)
- **Airflow:** `make up` / `make down`
- **Reports:** `make report-fixture`, `make report-pdf`, `make report`, `make report-incident RUN=<id>`, `make report-weekly`

Type hints are required on every function signature; there is no `make typecheck`
target in this repo. On Windows: `tasks.bat <target>` (kept in sync by
`tests/smoke/test_make_parity.py`).

## Repo layout

- `airflow/` — DAGs, listeners, callbacks
- `contracts/` — `registry.json` + one column contract per source table (schema source of truth)
- `data/raw/{mysql,mongo,databricks}/` — gzipped CSV snapshots + the loader/export scripts
- `sql/scripts/` — bootstrap (schemas, audit, registry); `sql/{staging,analytics,marts}/` — numbered load procedures
- `src/` — extract jobs, landing/Spark I/O, utils (config, connection, logger)
- `tests/` — `unit/`, `smoke/`, `data-quality/{raw,staging,analytics,marts}/`
- `reports/` — daily/incident/weekly PDF reports; `docs/` — project documentation

## Critical rules (summary of `AGENTS.md` — that file wins on any conflict)

- **Money:** `Decimal` in Python, `NUMERIC(18,2)` in SQL. Never `float`.
- **SQL:** explicit column lists, no `SELECT *`, uppercase keywords, `snake_case` names.
- **Procedures:** no `COMMIT`/`ROLLBACK` inside, take the advisory lock, return counts via `OUT`.
- **Naming:** procedures are schema-qualified — `staging.sp_load_*`, `analytics.sp_load_dim|fact_*`,
  `marts.sp_load_mart_*`, masters `staging|analytics|marts.sp_load_all`.
- **Idempotency:** every load must be safe to run twice with the same input; watermarks
  advance only inside the load transaction.
- **SQL changes:** add a new numbered file (`sql/<area>/NN_<name>.sql`, next free number);
  never rewrite an already-applied file in a way that breaks idempotency.
- **Migrations are never edited after merge** — add a new file instead.
- **Logging:** `src/utils/logger.py` only; no `print`, never log row values or credentials.
- **Never:** commit `.env`/tokens, write to Databricks `public`, skip or weaken a test to go green,
  modify `.env*` without explicit permission.
- **Ask first:** push/merge to `main`, add or upgrade a dependency, run against Databricks
  or a non-dev environment, delete files you did not create.

## Where to look

- Architecture and layer ownership: `@ARCHITECTURE.md`
- Agent permissions, standards, pipeline invariants: `@AGENTS.md`
- Reporting rules (override everything for report code): `docs/REPORTING.md` §3, §13
- Step-by-step onboarding: `docs/QUICKSTART.md`; day-to-day operations: `docs/RUNBOOK.md`
