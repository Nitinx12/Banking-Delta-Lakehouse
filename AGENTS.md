# AGENTS.md

Rules for AI agents working in Banking-Delta-Lakehouse. Read `ARCHITECTURE.md` first. If this file and the architecture disagree on design, the architecture wins. Report-specific rules live in `docs/REPORTING.md` §3 and §13 — they override this file for report code.

## Project in one line

Daily pipeline: MySQL, MongoDB and Databricks `public` → PySpark → PostgreSQL (landing → staging → core → mart) → Databricks `core`/`mart`. Airflow orchestrates, stored procedures transform, Great Expectations validates.

## Permissions

**Allowed without asking**
- Create branches: `feature/*`, `fix/*`, `chore/*`, `docs/*`
- Commit (Conventional Commits) and open a pull request
- Create or edit GitHub Actions under `.github/workflows/`
- Create or edit `Makefile`, `.sh`, `.bat`, Dockerfiles and compose files
- Add tests, new migrations, DQ suites and docs

**Ask first**
- Merge or push to `main`
- Add or upgrade a dependency
- Change pools, SLO targets or the registry schema
- Delete files you did not create
- Run anything against Databricks or a non-dev environment

**Never**
- Commit `.env`, `file.txt`, tokens or passwords
- Write to Databricks `public`
- Edit a migration that has been merged (add a new one)
- Use `float` for money
- Force-push, or skip or weaken a test or check to get CI green
- Modify any `.env*` file without explicit user permission

## Git

- Branch from `main`, keep it short-lived, one concern per branch
- Commit format: `type(scope): summary` (`feat`, `fix`, `chore`, `docs`, `test`, `ci`, `refactor`)
- Open a PR and stop. Do not merge it

## Comments

- **Top of file or function: one short line** saying what it is for
- **Inline: a few words**, only to give the reason, never to restate the code
- No paragraph comments, no block comments between lines of code, no section banners, no commented-out code
- If code needs a paragraph to explain, rename or split it instead

Python:

```python
"""Land MySQL tables into PostgreSQL, idempotent per run."""


def land_table(df: DataFrame, run_id: str) -> int:
    """Write one table to landing and return the row count."""
    df = df.withColumn("_run_id", lit(run_id))  # tag for replay
    df = df.dropDuplicates(["customer_id"])  # source can repeat keys
    return write_landing(df)
```

SQL:

```sql
-- SCD2 load for dim_customer. One transaction, no commit inside.
CREATE OR REPLACE PROCEDURE etl.sp_load_dim_customer(
    p_table_run_id BIGINT,
    OUT o_inserted BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE core.dim_customer AS d
    SET
        effective_to = s._extracted_at,
        is_current   = FALSE
    FROM staging.stg_customer AS s
    WHERE d.customer_id = s.customer_id
      AND d.is_current
      AND d._hash_t2 <> s._hash_t2;
END;
$$;
```

## Python standards

- PEP 8, formatted and linted with `ruff`, typed (`mypy`), Python version pinned in `pyproject.toml`
- Type hints on every function signature; short docstring on public functions
- `Decimal` for money, timezone-aware UTC datetimes, `pathlib` for paths
- Use the project logger from `src/utils/logger.py`. No `print`, and never log row values or credentials
- Read config through `src/utils/engine.py`, not `os.environ` scattered around
- Specific exceptions only. No bare `except`

## SQL standards

- Checked with `sqlfluff` (postgres dialect); uppercase keywords, `snake_case` names
- Explicit column lists. No `SELECT *` and no `INSERT` without columns
- Names follow `ARCHITECTURE.md` §4.2 (`etl.sp_<action>_<target>`, `dim_*`, `fact_*`, `_run_id`)
- Money is `NUMERIC(18,2)`, times are `timestamptz`
- Procedures never `COMMIT` or `ROLLBACK`, take the advisory lock, and return counts through `OUT` parameters
- Schema changes go in a new Flyway file: `V<n>__name.sql`, or `R__name.sql` for procedures

## Pipeline rules that must not break

- Watermarks advance only inside the load transaction
- Every load is safe to run twice with the same input
- A critical DQ failure blocks publish
- Landing, staging, core and mart are written only by the owners listed in `ARCHITECTURE.md`

## Scripts and automation

- `Makefile` is the entry point. Targets: `help`, `lint`, `test`, `up`, `down`, `migrate`, `dag-test`, `report-fixture`, `report-pdf`, `report-tex`, `report-docker`, `report`, `report-incident`, `report-weekly`, `report-clean`
- Every `.sh` starts with `set -euo pipefail`
- Every `.bat` starts with `@echo off` and `setlocal`, and mirrors the matching `make` target for Windows
- GitHub Actions: least-privilege `permissions:`, actions pinned by commit SHA, no `pull_request_target`, never echo secrets

## Done means

`make lint` and `make test` pass, new behaviour has a test, docs are updated if design changed, and the PR description says what changed and why.
