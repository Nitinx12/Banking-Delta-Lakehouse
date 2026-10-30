# System Interfaces Documentation

The Banking-Delta-Lakehouse pipeline implements a gated ETL flow from various sources (MySQL, MongoDB, Databricks) into a PostgreSQL warehouse, culminating in a publish phase to Databricks Delta marts for executive dashboarding.

## 1. CLI: main.py Execution
The `main.py` script acts as the local orchestrator for the daily pipeline.

**Flow: Input $\rightarrow$ Execution $\rightarrow$ Output**
- **Input**: CLI arguments (`--from`, `--only`, `--keep-going`).
- **Execution**: 
    - `build_steps()` defines the sequence: `raw-inject` $\rightarrow$ `raw-tests` $\rightarrow$ `staging-load` $\rightarrow$ `staging-tests` $\rightarrow$ `analytics-load` $\rightarrow$ `analytics-tests` $\rightarrow$ `marts-load` $\rightarrow$ `marts-tests` $\rightarrow$ `publish`.
    - **Script-based steps**: Executed via `subprocess.run` (e.g., `scripts/run_jobs.py`).
    - **Load-based steps**: `run_load()` deploys SQL procedures using `psql -f` and calls `schema.sp_load_all()`.
- **Output**: A rich console table summarizing the status, duration, and details of each step.

## 2. Airflow Daily DAG
The `banking_delta_daily.py` DAG provides production orchestration, delegating logic to the CLI and specialized scripts.

**Flow: Trigger $\rightarrow$ Task Sequence $\rightarrow$ Notification**
- **Trigger**: Scheduled (default `0 2 * * *`) or manual.
- **Task Sequence**:
    - `preflight` $\rightarrow$ `extracts` (parallel Mongo/DBX/MySQL) $\rightarrow$ `raw_tests` $\rightarrow$ `staging_load` $\rightarrow$ `staging_tests` $\rightarrow$ `analytics_load` $\rightarrow$ `analytics_tests` $\rightarrow$ `marts_load` $\rightarrow$ `marts_tests` $\rightarrow$ `publish`.
    - Logic is executed via `BashOperator` calling `banking_cmd()` (which wraps `main.py` or direct scripts).
- **Output**: Pipeline audit logs in PostgreSQL, failure notifications via `notify_task_failure`, and a final summary email.

## 3. Databricks Publishing: publish_marts.py
The `publish_marts.py` job moves refined marts from PostgreSQL to Databricks Delta tables.

**Flow: Discovery $\rightarrow$ Extraction $\rightarrow$ Loading**
- **Discovery**: `_discover()` identifies tables in the PostgreSQL `marts` schema.
- **Extraction**: 
    - Uses PySpark JDBC to read from PostgreSQL (`_read_mart`).
    - Writes data to local Parquet files using `pyarrow` (`_write_parquet`).
- **Loading**:
    - Uploads Parquet files to a Unity Catalog volume via `WorkspaceClient` (`_upload`).
    - Executes a Databricks SQL `INSERT OVERWRITE` using `read_files()` to update the Delta table (`publish_table`).
- **Output**: Updated Delta tables in the Databricks `marts` schema.

## 4. Streamlit Dashboard Data Access
The dashboard provides an executive view by querying the Databricks marts.

**Flow: UI Request $\rightarrow$ Cached Query $\rightarrow$ Rendering**
- **Request**: User navigates to a page (e.g., `dashboard/app.py`).
- **Data Access**:
    - High-level loaders in `dashboard/helpers/marts.py` (e.g., `load_kpi_monthly()`) call `lib/db.py:run_query()`.
    - `run_query()` uses `databricks-sql-connector` to execute `SELECT *` against the `marts` schema.
    - Results are cached via `@st.cache_data` with a default TTL of 300s.
- **Rendering**: DataFrames are cast to floats/dates and rendered using Plotly charts (`lib/charts.py`).

## Connections Summary
- `Airflow DAG` $\rightarrow$ calls $\rightarrow$ `main.py` / `scripts/` / `publish_marts.py`.
- `main.py` $\rightarrow$ triggers $\rightarrow$ `PostgreSQL Procedures` $\rightarrow$ populates $\rightarrow$ `marts` schema.
- `publish_marts.py` $\rightarrow$ reads $\rightarrow$ `PostgreSQL marts` $\rightarrow$ writes $\rightarrow$ `Databricks Delta`.
- `Streamlit App` $\rightarrow$ reads $\rightarrow$ `Databricks Delta`.

## Open Questions / UNVERIFIED
- **Watermarks**: `publish_marts.py` has logic for incremental watermarks (`_where_clause`), but `publish_table` currently uses full overwrite (lines 485-488). Unverified if incremental publishing is active for any specific table.
- **Spark Memory**: Airflow sets `SPARK_DRIVER_MEMORY`, but it is unverified how this affects `publish_marts.py` when run locally via `main.py`.
