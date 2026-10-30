# Data & State Documentation

Banking-Delta-Lakehouse is a daily lakehouse pipeline that moves data from MySQL, MongoDB, and Databricks through a four-layer PostgreSQL warehouse (`raw` → `staging` → `analytics` → `marts`) before publishing final marts back to Databricks Delta tables. It uses a gated architecture where each layer must pass Data Quality (DQ) checks before the next layer loads.

## 1. Schemas & Layers

| Layer | Schema | Owner | Purpose | Key Symbols/Files |
|---|---|---|---|---|
| **Landing** | `raw` | `src/jobs/extract_*.py` | Verbatim source copies + `_batch_id`, `_loaded_at` | `sql/raw/*.sql` (exploration) |
| **Cleansing** | `staging` | `staging.sp_load_*` | Typed, deduped, SCD1 state | `sql/staging/00_master_load.sql`, `sql/staging/01_sp_load_customers_scd1.sql` |
| **Modelling** | `analytics` | `analytics.sp_load_*` | Star schema (`dim_*`, `fact_*`) | `sql/analytics/00_master_load.sql`, `sql/analytics/01_dim_customer.sql` |
| **Serving** | `marts` | `marts.sp_load_*` | Business-shaped KPI/Report tables | `sql/marts/00_master_load.sql`, `sql/marts/01_mart_customer_360.sql` |
| **Audit** | `audit` | `src/utils/audit.py` | Pipeline runs, errors, watermarks, DQ | `sql/scripts/02_audit_tables.sql` |

## 2. State Management & Watermarks

State is managed via two distinct watermark stores in the `audit` schema to ensure idempotency and prevent data loss.

### Extract Watermarks (`audit.extract_watermarks`)
- **Purpose**: Tracks the last source value landed into `raw`.
- **Logic**: `[last_watermark, MAX(source_col)]`.
- **Management**: `src/utils/spark_io.py` handles `advance_watermark` within the same transaction as the data write.
- **Bootstrap**: `scripts/seed_watermarks.py`.

### ETL Watermarks (`audit.etl_watermarks`)
- **Purpose**: Tracks the last `raw` value consumed into `staging` and subsequent layers.
- **Logic**: Defaults to `_loaded_at` timestamp.
- **Management**: Advanced by `sp_load_*` procedures in SQL.

**Concurrency Control**: Both use optimistic locking via `lock_version` to prevent race conditions between parallel runs.

## 3. Data Lifecycle & Migrations

### Lifecycle Flow
1. **Extraction**: `src/jobs/extract_*.py` $\to$ `raw._stg_<table>` $\to$ `raw.<table>` (Promote).
2. **Processing**: `raw` $\to$ `staging` $\to$ `analytics` $\to$ `marts` via stored procedures.
3. **Validation**: `tests/data-quality/{layer}/*.sql` procedures execute and write to `audit.dq_run`.
4. **Publishing**: `src/jobs/publish_marts.py` $\to$ Parquet $\to$ Databricks Unity Catalog $\to$ Delta Tables.

### Migrations
Follows a Flyway-style sequential script approach located in `sql/scripts/`:
- `00_create_database.sql`: DB initialization.
- `01_init_schemas.sql`: Schema creation.
- `02_audit_tables.sql`: Audit system setup.
- `03_register_sources.sql`: Source registry configuration.

## 4. Connection to Other Parts

- **Orchestration**: Airflow (`airflow/dags/banking_delta_daily.py`) triggers `main.py`, which sequences the load and test steps.
- **Data Quality**: The `tests/data-quality` suites act as gates; a failure in `audit.dq_run` blocks the `publish_marts.py` step.
- **Consumption**: The Streamlit dashboard (`dashboard/`) reads directly from the published Databricks Delta tables.

## 5. Open Questions / UNVERIFIED

- **SCD2 Implementation**: `AGENTS.md` mentions SCD2 for `dim_customer` in an example, but `sql/staging` files are named `_scd1`. Need to verify if SCD2 is actually implemented in `analytics` or if it's strictly SCD1.
- **Watermark Reset**: Process for manually resetting a watermark if a batch is corrupted is not explicitly documented in the code (likely manual SQL update to `audit.extract_watermarks`).
- **Delta Lookback**: `publish_marts.py` uses a lookback period for date watermarks; the exact logic for determining "missing" data in the target is not fully verified.
