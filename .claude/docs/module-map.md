# Module Map - Banking-Delta-Lakehouse

A daily lakehouse pipeline extracting from MySQL, MongoDB, and Databricks into a multi-layered PostgreSQL warehouse, publishing final marts to Databricks Delta for consumption.

## Directory Map

### `src/`
- **Purpose**: Core Python logic for data extraction, publishing, and shared utilities.
- **Key Files**:
    - `jobs/extract_*.py`: Source-specific extractors.
    - `jobs/publish_marts.py`: Pushes PG marts to Databricks Delta.
    - `utils/extract_runner.py`: Shared orchestration logic for extraction batches.
    - `utils/spark_io.py`: Spark-to-PG read/write and watermark management.
    - `utils/audit.py`: Pipeline and table run tracking.
- **Public Interfaces**: `extract_runner.run_extraction()`, `publish_marts.main()`.
- **Dependencies**: PySpark, psycopg2, pymysql, pymongo, databricks-sql-connector.

### `sql/`
- **Purpose**: Database schema definitions and ETL transformations.
- **Key Files**:
    - `scripts/00-07`: Bootstrap scripts (schemas, audit, registry).
    - `staging/sp_load_*`: SCD1 cleansing procedures.
    - `analytics/`: Star schema (`dim_*`, `fact_*`) implementation.
    - `marts/`: Business-shaped reporting tables.
- **Public Interfaces**: `staging.sp_load_all()`, `analytics.sp_load_all()`, `marts.sp_load_all()`.
- **Dependencies**: PostgreSQL (plpgsql).

### `tests/`
- **Purpose**: Quality assurance including Python unit tests and SQL data-quality suites.
- **Key Files**:
    - `data-quality/{raw,staging,analytics,marts}/*.sql`: SQL-based DQ checks.
    - `unit/`: Hermetic Python tests.
    - `smoke/`: Integration and contract checks (e.g., `test_sql_contract.py`).
- **Public Interfaces**: `pytest` markers (`unit`, `smoke`, `spark`, etc.).
- **Dependencies**: pytest, SQLFluff.

### `airflow/`
- **Purpose**: Orchestration and scheduling of the pipeline.
- **Key Files**:
    - `dags/banking_delta_daily.py`: Main pipeline DAG.
    - `include/banking_airflow/summary.py`: Run summary and email logic.
    - `include/banking_airflow/commands.py`: CLI wrapper for pipeline steps.
- **Public Interfaces**: Airflow DAG API.
- **Dependencies**: Apache Airflow 3.3.2, CeleryExecutor.

### `dashboard/`
- **Purpose**: Read-only business visualization.
- **Key Files**:
    - `app.py`: Main Streamlit entry point.
    - `pages/*.py`: Domain-specific views (KPI, Loans, etc.).
    - `lib/db.py`: Databricks SQL connection.
- **Public Interfaces**: Streamlit UI.
- **Dependencies**: Streamlit, Plotly, Databricks SQL.

### `r/`
- **Purpose**: Advanced statistical analysis and forecasting (read-only).
- **Key Files**:
    - `main.R`: Analysis entry point.
    - `R/*.R`: Analysis modules (forecasting, reconciliation).
    - `analyses/*.qmd`: Quarto report documents.
- **Public Interfaces**: `main.R`.
- **Dependencies**: R, renv, Quarto.

### `contracts/`
- **Purpose**: JSON schema definitions for source-to-raw landing.
- **Key Files**:
    - `source-table.schema.json`: Meta-schema for contracts.
    - `mysql/*.json`, `mongodb/*.json`, `databricks/*.json`: Table-level contracts.
    - `validate.py`: Contract validation logic.
- **Public Interfaces**: `contracts.validate.validate_contract()`.
- **Dependencies**: jsonschema.

### `scripts/`
- **Purpose**: Thin CLI wrappers for manual execution and Airflow tasks.
- **Key Files**:
    - `run_jobs.py`: Executes extractors in sequence.
    - `run_{layer}_tests.py`: Executes SQL DQ suites for specific layers.
    - `seed_watermarks.py`: Bootstraps incremental loads.
- **Public Interfaces**: CLI arguments.
- **Dependencies**: `src/` utilities.

## Connectivity
- **Orchestration**: `airflow/` $\rightarrow$ `scripts/` $\rightarrow$ `src/` (Python) & `sql/` (PostgreSQL `CALL`).
- **Data Flow**: Source $\rightarrow$ `src/jobs/extract_*` $\rightarrow$ `sql/staging` $\rightarrow$ `sql/analytics` $\rightarrow$ `sql/marts` $\rightarrow$ `src/jobs/publish_marts` $\rightarrow$ Databricks.
- **Quality Gate**: `scripts/run_*_tests.py` $\rightarrow$ `tests/data-quality/` $\rightarrow$ `audit` schema $\rightarrow$ Airflow Gate.
- **Consumption**: Databricks $\rightarrow$ `dashboard/` & `r/`.

## Open questions / UNVERIFIED
- **SQL Linting**: `ARCHITECTURE.md` mentions `sql-lint` is currently red on some pre-existing violations.
- **R-Layer Integration**: The R layer is marked as a "read-only consumer"; verify if it has any write-back paths to audit or logs.
- **Airflow-Spark JVM**: The `spark_jvm` pool in Airflow suggests resource constraints; verify if this is based on physical memory or concurrency limits.
