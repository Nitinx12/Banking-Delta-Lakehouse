# Architecture — Banking-Delta-Lakehouse

A daily lakehouse pipeline that lands data from MySQL, MongoDB, and Databricks into a PostgreSQL warehouse, transforms it through four strict layers (`raw` → `staging` → `analytics` → `marts`), and publishes the final marts to Databricks Delta for dashboard consumption.

## Overall Design
The system follows a **gated pipeline pattern**. Each layer must pass a set of Data Quality (DQ) tests before the subsequent layer begins loading. This prevents "pollution" of downstream analytics by ensuring only valid data is promoted.

### Data Flow Layers
1.  **Raw (`raw` schema)**: Verbatim landing of source data. 
    - **Owner**: Spark extractors (`src/jobs/extract_*.py`).
    - **Pattern**: Snapshot $\rightarrow$ Write to transient `raw._stg_*` $\rightarrow$ Atomic promote to `raw.*` + advance watermark.
2.  **Staging (`staging` schema)**: Typed, deduped, and SCD1 (current state) representation.
    - **Owner**: PostgreSQL stored procedures (`sql/staging/sp_load_*`).
3.  **Analytics (`analytics` schema)**: Star schema containing `dim_*` (dimensions) and `fact_*` (facts).
    - **Owner**: PostgreSQL stored procedures (`sql/analytics/sp_load_*`).
4.  **Marts (`marts` schema)**: Business-shaped tables (KPIs, Fraud, Portfolio).
    - **Owner**: PostgreSQL stored procedures (`sql/marts/sp_load_*`).
5.  **Consumption (Databricks)**: Final published Delta tables.
    - **Owner**: `src/jobs/publish_marts.py`.

## Entry Points & Runtime Flow

### 1. Orchestration
- **Airflow**: The primary scheduler. The DAG `airflow/dags/banking_delta_daily.py` wires tasks together but contains no business logic.
- **CLI**: `main.py` allows manual execution of the same 9-step gated sequence.

### 2. Execution Sequence
`main.py` (and the Airflow DAG) executes the following sequence:
1.  **`raw-inject`**: Calls `scripts/run_jobs.py` $\rightarrow$ invokes Spark extractors.
30: 2.  **`raw-tests`**: Calls `scripts/run_raw_tests.py`.
31: 3.  **`staging-load`**: Calls `staging.sp_load_all()` in PostgreSQL.
32: 4.  **`staging-tests`**: Calls `scripts/run_staging_tests.py`.
33: 5.  **`analytics-load`**: Calls `analytics.sp_load_all()` in PostgreSQL.
34: 6.  **`analytics-tests`**: Calls `scripts/run_analytics_tests.py`.
35: 7.  **`marts-load`**: Calls `marts.sp_load_all()` in PostgreSQL.
36: 8.  **`marts-tests`**: Calls `scripts/run_marts_tests.py`.
9.  **`publish`**: Runs `src/jobs/publish_marts.py` to push data to Databricks.

## Key Design Patterns
- **Idempotency**: Every load is safe to run twice. This is achieved via watermarks and "Truncate-and-Insert" for full loads.
- **Watermark Isolation**: Separate stores for `audit.extract_watermarks` (source $\rightarrow$ raw) and `audit.etl_watermarks` (raw $\rightarrow$ staging/analytics/marts).
- **Atomic Promotion**: Data is written to a staging table first; a single PostgreSQL transaction promotes it to the target and updates the watermark.
- **Audit-First**: All runs are tracked in the `audit` schema using independent transactions (`src/utils/audit.py`) so that failure records survive the rollback of the data load.

## How this connects to other parts
- **Infrastructure**: Relies on PostgreSQL for the warehouse and Databricks for the lakehouse serving layer.
- **Dashboard**: The Streamlit app in `dashboard/` reads exclusively from the published Databricks Delta tables.
- **CI/CD**: `Makefile` and GitHub Actions enforce a "hermetic" gate (linting, unit tests, and contract validation) before code reaches the environment.

## Open questions / UNVERIFIED
- **R Analysis Layer**: Mentioned in `ARCHITECTURE.md` (`r/` directory), but not part of the primary daily pipeline flow. Its integration depth is unverified.
- **SCD2 Implementation**: `ARCHITECTURE.md` mentions SCD2 in a SQL example, but the summary table describes staging as SCD1. Need to verify if `analytics` or `marts` use SCD2.
