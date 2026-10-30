# Banking-Delta-Lakehouse Conventions

A high-integrity daily pipeline moving data from MySQL, MongoDB, and Databricks into a PostgreSQL warehouse (Landing → Staging → Analytics → Marts) and finally publishing to Databricks Delta. The system is built for idempotency, strict layer ownership, and gated data quality.

## Naming Conventions

### Python
- **Files:** `snake_case`. Extractors follow `extract_<source>.py` (e.g., `src/jobs/extract_mysql.py`).
- **Functions:** `snake_case` with mandatory type hints on all signatures.
- **Constants:** `UPPER_SNAKE_CASE` (e.g., `PROJECT_ROOT` in `src/utils/config.py`).
- **Classes:** `PascalCase` (e.g., `TableRun` in `src/utils/audit.py`).

### SQL
- **Keywords:** `UPPERCASE`.
- **Identifiers:** `snake_case`.
- **Schemas:** `raw`, `staging`, `analytics`, `marts`, `audit`.
- **Tables:**
    - Dimensions: `dim_*` (e.g., `analytics.dim_customer`).
    - Facts: `fact_*` (e.g., `analytics.fact_transactions`).
    - Marts: `mart_*` (e.g., `marts.mart_customer_360`).
    - Staging: `stg_*` or same as source (e.g., `staging.customers`).
- **Procedures:** `etl.sp_<action>_<target>` (e.g., `staging.sp_load_customers_scd1`).
- **Columns:** `_run_id`, `_batch_id`, `_loaded_at` for audit/lineage.

## File Layout
- `src/jobs/`: Data extractors and publishers.
- `src/utils/`: Cross-cutting logic (connection, spark session, audit, logger).
- `sql/`: Layered SQL scripts (staging, analytics, marts) and bootstrap scripts.
- `tests/data-quality/`: SQL-based DQ suites organized by layer (`raw`, `staging`, etc.).
- `tests/smoke/` & `tests/unit/`: Hermetic Python tests.
- `airflow/`: DAG definitions and orchestration logic.

## Engineering Patterns

### Error Handling & Logging
- **Logging:** Use `src/utils/logger.py` via `get_logger(__name__)`. No `print()` allowed.
- **Redaction:** Secrets are redacted in logs and audit tables using `_redact` (see `src/utils/audit.py:71`).
- **Audit Persistence:** Audit writes (`audit.pipeline_runs`, `audit.table_runs`) use plain `psycopg2` in their own transactions to ensure failure records survive data rollbacks.
- **Exceptions:** Use specific exceptions; no bare `except`.

### Data Pipeline Patterns
- **Idempotency:** Every load is safe to run twice.
- **Watermarks:** Two separate stores: `audit.extract_watermarks` (source → raw) and `audit.etl_watermarks` (raw → staging).
- **Optimistic Locking:** Watermarks use `lock_version` to prevent concurrent run conflicts.
- **SCD Type 1:** Implemented in staging with a shared `staging.scd1_history` table to track column-level changes.
- **DQ Gates:** SQL procedures in `tests/data-quality/` must `COMMIT` results before `RAISE` on failure to preserve the error record.

### Testing Style
- **Pytest Markers:** Tests are categorized by markers: `unit`, `smoke`, `spark`, `integration`, `live`.
- **Hermeticity:** `unit` and `smoke` tests block network/socket access via `conftest.py`.
- **DQ Suites:** SQL files prefixed with numbers (e.g., `01_lp_check_metadata_col.sql`) and a `00_master_*.sql` entry point.

### Import Rules
- **Environment:** `.env` is read ONLY in `src/utils/config.py`.
- **Circular Imports:** Avoided by using `from . import config` with `# noqa: F401` where needed (e.g., `src/utils/logger.py:12`).

## Connections to Other Parts
- `main.py` $\rightarrow$ `scripts/run_jobs.py` $\rightarrow$ `src/jobs/extract_*.py` $\rightarrow$ `src/utils/spark_io.py`.
- `Airflow DAG` $\rightarrow$ `main.py` logic $\rightarrow$ `PostgreSQL` $\rightarrow$ `audit` schema.
- `SQL Procedures` $\rightarrow$ `audit.etl_watermarks` $\rightarrow$ `audit.table_runs`.

## Open Questions / UNVERIFIED
- **SQL-Lint Status:** `ARCHITECTURE.md` mentions `sql-lint` is currently red on pre-existing violations.
- **R Layer:** The `r/` directory is listed as a read-only consumer; integration depth is unverified.
- **Unity Catalog:** Volume upload logic in `publish_marts.py` depends on Workspace SDK; requires specific environment setup.

## Anti-Patterns to Avoid
- **Money as Float:** NEVER use `float` for currency; use `NUMERIC(18,2)` in SQL and `Decimal` in Python.
- **Mixed Watermarks:** Never use `extract_watermarks` logic for ETL layers or vice-versa.
- **Direct Schema Edits:** Never hand-edit `raw`, `staging`, `analytics`, or `marts`. Always use extractors or stored procedures.
- **Implicit Column Lists:** Avoid `SELECT *` and `INSERT` without explicit column lists.
