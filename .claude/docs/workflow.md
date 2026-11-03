# Dev Workflow: Banking-Delta-Lakehouse

The project uses a PySpark-based ETL pipeline orchestrating data from MySQL, MongoDB, and Databricks into PostgreSQL, then back to Databricks. Development is managed via `uv` for Python dependency management and `Makefile` / `tasks.bat` for task orchestration.

## Core Commands

### Setup
- **Install Dependencies**: `make install` or `tasks install` (`uv sync --group dev`)
- **Enable Git Hooks**: `make hooks` or `tasks hooks` (sets `core.hooksPath` to `.githooks/`)

### Static Analysis & Quality
- **Lint & Format Check**: `make lint` or `tasks lint` (`ruff check` + `ruff format --check`)
- **Auto-format**: `make format` or `tasks format` (`ruff check --fix` + `ruff format`)
- **SQL Lint**: `make sql-lint` or `tasks sql-lint` (`sqlfluff lint` for postgres dialect)
- **Contract Validation**: `make contracts` or `tasks contracts` (`python -m contracts.validate`)
- **Typecheck**: None — there is no mypy/`make typecheck` target; type hints are mandatory and `make lint` (ruff) is the gate.

### Testing
- **Unit Tests**: `make unit` or `tasks unit` (`pytest -m unit`)
- **Coverage**: `make cov` or `tasks cov` (`pytest -m unit --cov`)
- **Smoke Tests**: `make smoke` or `tasks smoke` (`pytest -m smoke`)
- **Spark-specific Smoke**: `make spark-smoke` or `tasks spark-smoke` (`pytest -m spark`)
- **Integration Tests**: `make integration` or `tasks integration` (requires `ALLOW_SQL_SMOKE=1` and disposable DB)
- **Live Health Checks**: `make smoke-live` or `tasks smoke-live` (`pytest -m live`)

### Database & Pipeline
- **Migrations**: Numbered SQL files per folder (`sql/<area>/NN_<name>.sql`, next free number); see `ARCHITECTURE.md` and `AGENTS.md`.
- **Local Stack**: `make up` / `make down` (Docker Compose for Airflow)
- **Full Pipeline Run**: `make daily` or `tasks daily` (Runs `run-jobs` $\to$ `dq-raw` $\to$ `staging` $\to$ `dq-staging` $\to$ `analytics` $\to$ `dq-analytics` $\to$ `marts` $\to$ `dq-marts` $\to$ `publish`)
- **Data Quality (DQ) Gates**: `make dq` or `tasks dq` (runs all layer-specific DQ scripts in `scripts/run_<layer>_tests.py`)

## CI Pipeline (`.github/workflows/ci.yml`)

The CI gate ensures parity across environments and blocks merges on failure:
1. **Workflow Lint**: `actionlint` and `zizmor` for GH Action security/syntax.
2. **Gate (Ubuntu)**: `make install` $\to$ `make lint` $\to$ `make contracts` $\to$ `make sql-lint` $\to$ `make smoke` $\to$ `make cov`.
3. **Dep Audit**: `pip-audit` via `uv export` to check for vulnerabilities.
4. **Windows Gate**: Mirrors the Ubuntu gate using `.\tasks.bat` to ensure Windows parity.
5. **Pipeline (Main only)**: Runs `uv run main.py --keep-going` against real sources if secrets are present.
6. **Aggregation**: `ci-success` job consolidates all results for branch protection.

## Connections
- **Orchestration**: Airflow triggers the PySpark jobs defined in `src/jobs/`.
- **Transformation**: PySpark lands data; PostgreSQL stored procedures (`sql/`) handle internal transformations.
- **Validation**: SQL DQ suites (`audit.dq_*` procedures in `tests/data-quality/`), one gate per layer before publish.

## Open questions / UNVERIFIED


- **R-Analysis**: The `r-` targets in `Makefile` exist but are noted as "NOT part of ci".
