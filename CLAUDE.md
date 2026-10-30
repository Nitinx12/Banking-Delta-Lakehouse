# Banking Delta Lakehouse

Daily pipeline moving data from MySQL, MongoDB, and Databricks `public` via PySpark into PostgreSQL (landing → staging → core → mart), then back to Databricks `core`/`mart`. Airflow orchestrates the flow, stored procedures handle transformations, and Great Expectations ensures data quality.

## Tech Stack
- **Languages:** Python (PySpark), SQL (PostgreSQL)
- **Orchestration:** Airflow
- **Database:** PostgreSQL, Databricks
- **Validation:** Great Expectations
- **Tooling:** Ruff, Mypy, Sqlfluff, Flyway, Make

## Commands
- **Lint:** `make lint`
- **Test:** `make test`
- **Typecheck:** `make typecheck` (via `mypy` in lint)
- **Build/Setup:** `make up`

## Repo Layout
- `airflow/`: DAGs and orchestration logic
- `sql/`: Flyway migrations and stored procedures
- `src/`: PySpark landing and utility code
- `docs/`: Project documentation and reporting rules
- `reports/`: Reporting templates and logic

## Critical Rules & Gotchas
- **Money:** Use `Decimal` in Python and `NUMERIC(18,2)` in SQL. Never use `float`.
- **SQL:** Use explicit column lists; no `SELECT *`. Keywords must be uppercase.
- **Procedures:** No `COMMIT` or `ROLLBACK` inside procedures; use `OUT` parameters for counts.
- **Idempotency:** Every load must be safe to run twice with the same input.
- **Migrations:** Never edit a merged migration; always create a new Flyway file.
- **Logging:** Use `src/utils/logger.py`; no `print` statements or logging of credentials.

## Where to Look
- Architecture: @ARCHITECTURE.md
- System Map: @ARCHITECTURE.md
