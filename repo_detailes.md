# Repo Details — Banking-Delta

Everything about this repository: what each file does, how the pieces connect, how data
flows end to end, and how it is tested. Read `AGENTS.md` first for the rules agents must
follow; this file is the deep reference.

---

## 1. What this repo is

A daily data pipeline: **MySQL, MongoDB and Databricks `public` schema → PySpark →
PostgreSQL warehouse (`raw → staging → analytics → marts`) → Databricks Delta marts.**
SQL stored procedures do the transformations, Great-Expectations-style SQL procedures do
data quality, and every step writes an audit trail into the `audit` schema of the same
PostgreSQL warehouse.

| System | Role | Access |
|---|---|---|
| MySQL `banking_core_db` | Source: branches, customers, accounts, cards, employees | Spark JDBC (read), pymysql (metadata/MAX) |
| MongoDB `banking_support_db` | Source: support_tickets, card_transactions | mongo-spark-connector (read), pymongo (count/MAX) |
| Databricks `public` schema | Source: loans, loan_payments, transactions | Pure-Python `databricks-sql-connector` → local Parquet → Spark |
| PostgreSQL `banking_delta` | Warehouse: raw / staging / analytics / marts / audit / exploration schemas | psycopg2 (audit + SQL procedures), Spark JDBC (bulk landing writes) |
| Databricks `marts` schema | Final Delta marts (published) | databricks-sql-connector + Workspace SDK volume upload |
| Streamlit dashboard (`dashboard/`) | Read-only BI over the Databricks `marts` (see §16) | databricks-sql-connector (SELECT only) |

There is **no Airflow DAG code in the repo yet** (env vars and `AIRFLOW_CTX_*` plumbing
exist in the runner, the DAGs themselves live outside).

---

## 2. End-to-end pipeline flow

```
 MySQL          MongoDB           Databricks public
   |               |                     |
   |  Spark JDBC   |  mongo connector    |  SQL connector -> local parquet -> Spark
   +-------+-------+----------+----------+
           |                  |
           v                  v
   [1] EXTRACT  (src/jobs/extract_*.py, orchestrated by scripts/run_jobs.py)
           |  Spark writes raw._stg_<table>  (staging table, mode overwrite)
           |  ONE PG transaction:  _stg_ -> raw.<table>  (+ advance extract watermark)
           |  DROP raw._stg_<table>
           v
   [2] STAGING  (CALL staging.sp_load_all()   — sql/staging/*.sql)
           |  raw.*  ->  staging.*  (cleaned, deduped, typed, SCD1/SCD2 history)
           |  incremental via audit.etl_watermarks (raw._loaded_at)
           v
   [3] ANALYTICS (CALL analytics.sp_load_all() — sql/analytics/*.sql)
           |  staging.*  ->  analytics.dim_* / analytics.fact_*
           v
   [4] MARTS    (CALL marts.sp_load_all()     — sql/marts/*.sql)
           |  analytics.*  ->  marts.mart_*   (PostgreSQL business marts)
           v
   [5] PUBLISH  (python src/jobs/publish_marts.py)
           |  marts.mart_*  ->  Parquet  ->  Databricks volume  ->  MERGE INTO Delta
           v
   [6] DQ GATES (python scripts/run_*_tests.py, after each layer)
             tests/data-quality/<layer>/*.sql  ->  audit.dq_run / audit.dq_violation
```

Steps 2–5 run inside PostgreSQL/Databricks as stored procedures; only steps 1 and 5 are
Python jobs. Step 6 is a gate: a critical failure blocks publish.

### Typical daily command sequence

The **single entry point** for all of this is `python main.py` (see §14); it runs the 9
steps below in order and stops on the first failure. The individual commands are kept here
because they are what each step actually invokes (and what you run when debugging one
layer):

```bash
python scripts/run_jobs.py                 # [1] mongo -> databricks -> mysql extracts
psql ... -f sql/staging/00_master_load.sql # [2] CALL staging.sp_load_all()
psql ... -f sql/analytics/00_master_load.sql  # [3]
psql ... -f sql/marts/00_master_load.sql   # [4]
python src/jobs/publish_marts.py           # [5] push marts to Databricks Delta
python scripts/run_raw_tests.py            # [6a] raw DQ gate
python scripts/run_staging_tests.py        # [6b]
python scripts/run_analytics_tests.py      # [6c]
python scripts/run_marts_tests.py          # [6d]
```

---

## 3. Repository layout

```
Banking/
├── AGENTS.md                   # rules for AI agents (permissions, git, code standards)
├── repo_detailes.md            # this file
├── main.py                     # pipeline entrypoint: runs the 9 gated steps in order (see §14)
├── pyproject.toml              # project metadata + dependencies (uv-managed)
├── requirements.txt            # pip-style mirror of the runtime deps
├── uv.lock                     # uv lockfile
├── .env / .env.example         # all secrets/config; .env is git-ignored
├── .pre-commit-config.yaml     # trailing-ws, ruff, sqlfluff, conventional-commit hooks
├── .githooks/                  # git hooks (enable: git config core.hooksPath .githooks)
│   ├── commit-msg              # conventional-commit message gate
│   ├── pre-commit              # secrets guard + ruff on staged files
│   └── pre-push
├── conf/
│   └── log4j2.properties       # Spark/Java logging config
├── notebooks/                  # one exploration notebook per source system
│   ├── mysql.ipynb  mongodb.ipynb  databricks.ipynb
├── dashboard/                  # Streamlit + Plotly dashboard over the Databricks marts (see §16)
├── scripts/                    # operator entry points (see §5)
├── src/
│   ├── jobs/                   # runnable jobs (see §6)
│   └── utils/                  # shared library (see §4)
├── sql/                        # all warehouse DDL/procedures (see §7)
│   ├── scripts/  raw/  staging/  analytics/  marts/  metadata/
└── tests/
    └── data-quality/           # SQL DQ test procedures per layer (see §9)
        ├── raw/  staging/  analytics/  marts/
```

Runtime scratch dirs (git-ignored): `.spark/` (Ivy jar cache, temp Parquet, warehouse),
`logs/`.

---

## 4. `src/utils/` — the shared library

### `config.py` — environment loading
The **one** place `.env` is read. `load_dotenv(override=False)` so shell/Airflow/CI
exports always win. Exposes `PROJECT_ROOT` (overridable via `PROJECT_ROOT` env for
Airflow where cwd is not the repo) and `require(name)` which fails with a clear message
on a missing variable.

### `logger.py` — project logger
`get_logger(name)` returns the shared loguru-style logger (`banking.*` namespace, seen in
job output as `banking.extract_mongo`, `banking.utils.audit`, …). Rule: never `print`,
never log row values or credentials.

### `connection.py` — connection factories
Plain-Python connections, credentials only from env, drivers imported lazily so each job
installs only what it needs:

| Factory | Used by |
|---|---|
| `get_pg_connection()` | audit writes, SQL runners, MAX/bounds queries |
| `get_mysql_connection()` | MySQL MAX watermark, column types, JDBC bounds |
| `get_mongo_client()` | Mongo MAX watermark, document counts |
| `get_databricks_connection()` | Databricks SQL warehouse (reads + publishes) |
| `mysql_jdbc()` / `pg_jdbc()` | Spark JDBC option dicts (secrets stay OUT of the URL; `useCursorFetch`, `reWriteBatchedInserts`, `stringtype=unspecified`) |
| `mongo_settings()` | Mongo Spark connector settings |

### `session.py` — sessions and transactions
- `get_spark_session(app, sources)` — process-wide SparkSession singleton; `stop_spark()`.
- `pg_transaction()` — context manager: commit on success, rollback on error, always close.
  Audit writes deliberately use their **own** transactions so a FAILED run is recorded even
  when the data transaction rolled back.
- `pg_cursor()`, `mysql_cursor()`, `mongo_database()` — one-connection convenience wrappers.
- Design: **no cached DB connections** — only Spark is a singleton.

### `engine.py` — the PySpark engine (262 lines)
`get_spark(app_name, sources)` builds one tuned local session (`master=local[*]`,
`spark.sql.session.timeZone=UTC`, driver memory from `SPARK_DRIVER_MEMORY`). Before
starting it runs pre-flight checks with actionable errors: Java present/supported
(8/11/17/21), Python worker == driver Python, Scala suffix of connector jars matches the
installed PySpark (3.5.x → Scala 2.12), Ivy cache lives inside the project (`.spark/ivy`)
so Windows paths with spaces cannot break it, and the right network interface is bound on
VPN/multi-NIC hosts.

Jars are downloaded **once** from Maven and cached in `.spark/ivy/jars`; only the jars the
current job needs are loaded:
- `org.postgresql:postgresql:42.7.4`
- `com.mysql:mysql-connector-j:8.4.0`
- `org.mongodb.spark:mongo-spark-connector_2.12:10.4.1`

### `audit.py` — the audit system (604 lines) — see §8 for the full model
Pipeline/table run tracking, error logging, the **two** watermark stores, DQ results,
stale-run reaping. All writes via psycopg2 (`RealDictCursor`, `psycopg2.sql` identifiers,
registered UUIDs). Every helper takes an optional `conn=`; without one it opens its own
short transaction. Key API:

| Function | Purpose |
|---|---|
| `start_pipeline_run` / `finish_pipeline_run` | One row per DAG run/manual run; `ON CONFLICT (dag_id, dag_run_id)` reuses a shared run |
| `table_run(...)` context manager | Starts a table attempt; on exception logs the error + marks FAILED, on success closes it with counts |
| `get_enabled_tables(source_name)` | Reads the table registry (`audit.source_tables ⨝ audit.source_registry`) |
| `begin_batch` / `advance_watermark` / `get_watermark` | Extract-window bookkeeping in `audit.extract_watermarks` (optimistic `lock_version`) |
| `seed_watermark` | Bootstrap a watermark for a newly-incremental table (never rewinds unless `--force`) |
| `log_dq_result` | Writes `audit.data_quality_results` (used by the extract row-count check) |
| `log_error` | Classifies (CONNECTION/CONCURRENCY/SPARK/DATA/UNKNOWN), redacts secrets, links back to the table run |
| `fail_stale_runs(6h)` | Reaps RUNNING rows older than 6 hours at the start of every job |

### `spark_io.py` — readers and writers (793 lines)
The load contract (docstring at the top of the file):

1. Snapshot the batch window: `start` = last watermark, `end` = MAX(incremental column) at the source.
2. Spark reads **only that window**, in parallel partitions.
3. Spark writes to a STAGING table `raw._stg_<table>` (parallel multi-row INSERTs).
4. ONE Postgres transaction: staging → raw table + advance watermark (atomic).
5. Drop staging.

If anything fails before step 4 commits, raw and the watermark are untouched — a retry
re-extracts the same window. No duplicates, no gaps.

| Group | Functions |
|---|---|
| Watermark readers | `mysql_max_watermark`, `mongo_max_watermark`, `databricks_max_watermark` (source MAX; Databricks datetimes normalized to naive UTC text) |
| Window predicates | `_mysql_where`, `_mongo_window` (`$match` extended JSON incl. `{"$oid":...}`/`{"$date":...}`), `_dbx_where` |
| Source counts | `mysql_count`, `mongo_count`, `databricks_count` (exact window counts for the row-count DQ check) |
| Readers | `read_mysql` (JDBC, cursor-fetch, optional partitioned reads with MIN/MAX bounds), `read_mongo` (connector + aggregation pipeline), `read_databricks` (SQL connector → Arrow batches → one local Parquet file → `spark.read.parquet`; avoids Hadoop dir-listing on Windows) |
| Mongo typing | `cast_temporal` (ISO text date/timestamp columns → real types), `temporal_parse_failures`, `cast_integers` (e.g. `customer_id` text → bigint) |
| JDBC prep | `prepare_for_jdbc` (detects nested fields → stored as `jsonb`), `add_audit_columns` (`_batch_id` = table-run UUID, `_loaded_at` = load time) |
| Landing | `write_staging` (Spark → `raw._stg_*`, coalesce to `num_partitions`, batchsize), `promote_staging` (staging → raw: creates target on first run, auto-adds new source columns (schema drift), TRUNCATE+INSERT for full loads / append for incremental, jsonb and exact MySQL type casts), `drop_staging` |

### `extract_runner.py` — the shared extract loop (231 lines)
All three extractors are thin shells around this:

- `Source` dataclass: name, app, Spark sources, `max_watermark`, `count`, `prepare`.
- `TableContext`: spark, pipeline_run_id, cfg, start/end, run, label, logger.
- `Prepared`: the DataFrame + promote kwargs + optional `after_dq` callback.
- `Extractor.run(argv)`: argparse (`--tables`, `--parallel`, `--finalize`, `--dag-id`,
  `--dag-run-id`), `fail_stale_runs`, `start_pipeline_run`, `get_enabled_tables`, one
  Spark session, a `ThreadPoolExecutor` (default `EXTRACT_PARALLEL`/`--parallel`, 3),
  `finish_pipeline_run` at the end. Airflow context comes from `AIRFLOW_CTX_*` env vars.
  Parallelism falls back to 1 worker if two independent PG connections cannot be proven.
- `Extractor.extract_table` — per table:
  - **incremental**: read watermark → `end = MAX(col)` at source → skip if no data or no
    change → `begin_batch` → window logged → watermark_start/end recorded on the run.
  - **full**: no watermark, whole table.
  - `prepare()` → `write_staging` → one transaction `promote_staging` + `advance_watermark`
    → `drop_staging` → `row_count_source_vs_landed` DQ (PASSED/WARNING) → `after_dq`.

---

## 5. `scripts/` — operator entry points

| Script | What it does |
|---|---|
| `run_jobs.py` | Orchestrates the extracts: one **subprocess** per source, in canonical order `mongo → databricks → mysql`, so only one Spark/Java instance is alive at a time. Flags: `--sources`, `--keep-going` (default stop at first failure). Unknown flags (e.g. `--tables a b`, `--parallel 2`, `--finalize`) are passed through to every job. Exit 0 only if all requested sources exit 0. |
| `seed_watermarks.py` | Bootstraps `audit.extract_watermarks` for newly-incremental tables: reads MAX at each source and seeds it, so the first incremental run picks up only newer rows instead of re-landing full history. Never rewinds an existing watermark (unless `--force`); `--dry-run` supported. Covers `mongodb_source` + `databricks_source` only (MySQL stays full). |
| `run_raw_tests.py` | Runs `tests/data-quality/raw/*.sql` (see §9). Rich output, progress bar, audit summary, exit 0 only if every test passes. Flags: `--only <substr>`, `--master`, `-v`, `--list`. |
| `run_staging_tests.py` | Same runner for `tests/data-quality/staging/`. |
| `run_analytics_tests.py` | Same runner for `tests/data-quality/analytics/`. |
| `run_marts_tests.py` | Same runner for `tests/data-quality/marts/`. |
| `list_raw_columns.py` | Small helper: prints table+column names of the **analytics** schema from `information_schema`. |

---

## 6. `src/jobs/` — the runnable jobs

### `extract_mongo.py`
`mongodb_source` → `raw.*`. `prepare()`: read (windowed) → `cast_temporal` (created_at /
loaded_at / txn_date are ISO **strings** in Mongo → real timestamp/date) →
`cast_integers` (customer_id / card_id) → `prepare_for_jdbc` (nested → jsonb) →
`add_audit_columns`. Registers a `temporal_values_parsed` WARNING DQ check for values that
failed to parse. Watermark: `_id` (ObjectId, strategy `objectid`) — the only monotonic,
indexed field, because the date fields are plain strings.

### `extract_databricks.py`
`databricks_source` (`public.*`) → `raw.*`. `prepare()`: `read_databricks` (SQL connector
→ Arrow → local Parquet → Spark) → `prepare_for_jdbc` → `add_audit_columns`. Watermark:
`created_at` (real TIMESTAMP on all three tables, strategy `timestamp`).

### `extract_mysql.py`
`mysql_source` (`banking_core_db.*`) → `raw.*`. Full loads: `read_mysql` (JDBC with
cursor fetch, optional numeric partition column for parallelism) →
`mysql_column_types` (information_schema → exact Postgres types, e.g. `varchar(n)`) →
`add_audit_columns`. No watermarks — MySQL tables stay `full`.

### `publish_marts.py` (726 lines)
Publishes PostgreSQL `marts.mart_*` tables into Databricks Delta (`marts` schema in
`DATABRICKS_CATALOG`).

- Hardcoded `MART_CONFIG`: business key(s), watermark column and kind per mart:

  | Mart | Watermark | Kind |
  |---|---|---|
  | mart_monthly_transactions | month_start | date |
  | mart_kpi_monthly | month_start | date |
  | mart_card_fraud | month_start | date |
  | mart_support_performance | month_opened | date |
  | mart_customer_360 | mart_refreshed_at | timestamp |
  | mart_branch_performance | mart_refreshed_at | timestamp |
  | mart_loan_portfolio | mart_refreshed_at | timestamp |

- Watermark is read **from the Delta target itself** (`SELECT max(wm) FROM target`), so
  publishing is self-incrementing: date watermarks re-read the last N months (late
  arrivals), timestamp watermarks use strict `>`.
- Flow per table: Spark/PG JDBC read (windowed) → pyarrow Parquet files → upload to a
  Unity Catalog **volume** via the Workspace SDK → SQL warehouse statement:
  `MERGE INTO target USING read_files(...) ON key` (update+insert) when the mart has
  keys, else `INSERT OVERWRITE`. Creates the Delta table on first publish
  (`USING DELTA`), auto-adds missing columns (schema drift).
- Tuning env vars: `PUBLISH_WORKERS`, `PUBLISH_WORKER_MIN_ROWS`, `PUBLISH_FETCH_SIZE`,
  `PUBLISH_MAX_PARAMS`.
- Audit: reuses `start_pipeline_run`/`finish_pipeline_run`, logs
  `row_count_source_vs_published` DQ results, and records per-table SUCCESS/FAILED.

---

## 7. `sql/` — the warehouse

### `sql/scripts/` — bootstrap (run in numeric order, all idempotent, guarded on
`current_database() = 'banking_delta'`)

| Script | Purpose |
|---|---|
| `00_create_database.sql` | Creates the `banking_delta` database |
| `01_init_schemas.sql` | Creates schemas `raw`, `staging`, `analytics`, `marts`, `audit` (+ `exploration` used by probe scripts) |
| `02_audit_tables.sql` | The audit schema: `source_registry`, `source_tables` (the **table registry**), `pipeline_runs`, `etl_watermarks` (staging layer), `table_runs`, `pipeline_errors` |
| `03_register_sources.sql` | Seeds the registry: 3 sources + 10 tables. Mongo & Databricks tables are **incremental** (`_id`/objectid, `created_at`/timestamp); MySQL tables are **full** |
| `04_dq_audit_tables.sql` | `audit.dq_run`, `audit.dq_violation`, view `audit.v_dq_latest` — the DQ gate's history |
| `05_switch_mongo_databricks_incremental.sql` | One-time flip of an already-seeded DB from full → incremental for Mongo+Databricks (03 uses `ON CONFLICT DO NOTHING`, so it cannot update existing rows) |
| `06_extract_watermarks.sql` | `audit.extract_watermarks` — source→raw extract progress, **separate** from `audit.etl_watermarks` (which tracks raw→staging progress). The two layers must never share a watermark value |

### `sql/raw/` — exploration/profiling queries (not part of the pipeline)
`01`–`10_explore_raw_*.sql`: deep profiling of each landed raw table — column inventory
from `information_schema`, shape/min/max of every column, date parsability, duplicates,
orphan keys, version changes over `_loaded_at`, DQ probe results. Used while building the
staging procedures. `sql/metadata/` holds generic inventory queries (all tables, column
counts, schemas, constraints, indexes, views, sequences, extensions, table sizes).

### `sql/staging/` — raw → staging (cleansing layer)
Each file creates one `staging.sp_load_<table>_scd1` procedure (SCD1 upsert; facts and
transactional tables behave the same). Every procedure:

1. Opens its own audit `table_runs` row (or reuses the master's pipeline run).
2. Reads `audit.etl_watermarks` for the last watermark (defaults to `_loaded_at`,
   strategy `timestamp`); `p_force_full` or a NULL watermark loads everything.
3. Filters `raw.<t>.<wm_col> > last_wm` (strict `>`), dedupes with
   `ROW_NUMBER() OVER (PARTITION BY key ORDER BY _batch_id DESC, _loaded_at DESC)`,
   and cleans every column (trim, regex-cast, range checks, standardised defaults).
4. Merges into `staging.<t>` (insert + update, history rows where applicable).
5. Advances `audit.etl_watermarks` in the same block, closes the `table_runs` row with
   counts, `watermark_start/end` and an `execution_metadata` jsonb.

`00_master_load.sql` → `CALL staging.sp_load_all(p_force_full => FALSE)` runs them in
parent→child order with one shared batch id and pipeline run:
customers → branches → employees → accounts → cards → card_transactions → loans →
loan_payments → transactions → support_tickets.

### `sql/analytics/` — staging → analytics (dimensional model)
`01_dim_customer`, `02_dim_account`, `03_dim_branch`, `04_dim_employee`, `05_dim_card`,
`06_fact_card_transactions`, `07_dim_loan`, `08_fact_loan_payments`, `09_dim_txn_profile`,
`10_fact_transactions`, `11_fact_support_tickets` (+ `99_debug_*`). Same incremental
pattern as staging, but dims keep a `source_row_updated_at` watermark **on the dim row**
with a NULL bootstrap and `p_force_full`. `00_master_load.sql` →
`CALL analytics.sp_load_all()`:
dims first (customer → branch → employee → account → card → loan → txn_profile), then
facts.

### `sql/marts/` — analytics → marts (business marts)
`01_mart_customer_360`, `02_mart_branch_performance`, `03_mart_monthly_transactions`,
`04_mart_loan_portfolio`, `05_mart_card_fraud`, `06_mart_support_performance`,
`07_mart_kpi_monthly`. `00_master_load.sql` → `CALL marts.sp_load_all()`. These PostgreSQL
marts are what `publish_marts.py` pushes to Databricks.

---

## 8. The audit system — how audit happens

Everything is in the `audit` schema of the warehouse, written with plain psycopg2.

### Run tracking
- **`audit.pipeline_runs`** — one row per pipeline execution. When run from Airflow,
  `ON CONFLICT (dag_id, dag_run_id)` makes the three parallel per-source tasks share one
  row; manual runs get `trigger_type='manual'`. `finish_pipeline_run` rolls table runs up
  into SUCCESS / PARTIAL / FAILED (per config, latest attempt only).
- **`audit.table_runs`** — one row per table **attempt** (`attempt_number` increments).
  Records status (RUNNING → SUCCESS/FAILED/SKIPPED), `rows_extracted`, `rows_landed`,
  `watermark_start/end`, Airflow task id/try number, duration, `execution_metadata` jsonb,
  and `error_id` on failure. `fail_stale_runs(6h)` reaps crashed RUNNING rows.
- **`audit.pipeline_errors`** — classified (`log_error`), secret-redacted error details
  linked from `table_runs.error_id`.

### The table registry
- **`audit.source_registry`** — `mongodb_source`, `mysql_source`, `databricks_source`.
- **`audit.source_tables`** — the config every extractor reads
  (`get_enabled_tables`): source + target names, `business_key`, `load_strategy`
  (`full`/`incremental`), `incremental_column`, `watermark_strategy`
  (`timestamp`/`numeric`/`objectid`), Spark tuning (`partition_column`, `num_partitions`,
  `fetch_size`, `batch_size`), `is_enabled`. A CHECK guarantees incremental tables always
  name a column + strategy.

Current registration:

| Source | Table | Strategy | Watermark |
|---|---|---|---|
| mongodb_source | support_tickets, card_transactions | incremental | `_id` (objectid) |
| databricks_source | loans, loan_payments, transactions | incremental | `created_at` (timestamp) |
| mysql_source | accounts, branches, cards, customers, employees | full | — |

### The two watermark stores (do not mix them)
| Table | Layer | Meaning | advanced by |
|---|---|---|---|
| `audit.extract_watermarks` | extract (source → raw) | "last source value landed into raw" | `advance_watermark` inside the extract transaction; bootstrapped by `scripts/seed_watermarks.py` |
| `audit.etl_watermarks` | staging (raw → staging) | "last raw value consumed into staging" | each `staging.sp_load_*` procedure (defaults to `_loaded_at`) |

Both use an optimistic `lock_version`: `begin_batch` snapshots it, `advance_watermark`
updates `WHERE lock_version = expected` and raises `WatermarkConflict` (→ rollback) if
another run won.

### DQ results
- `log_dq_result` → `audit.data_quality_results` (used inside extracts, e.g.
  `row_count_source_vs_landed`, Mongo `temporal_values_parsed`).
- The SQL DQ gate writes `audit.dq_run` + `audit.dq_violation` (see §9).

### Per-extract-run audit sequence
1. `fail_stale_runs(6h)` — reap crashed runs.
2. `start_pipeline_run` (shared across sources when Airflow context is present).
3. Per table: `table_run` opens a row → (incremental: `get_watermark` → source MAX →
   `begin_batch`) → Spark read/write → one transaction: `promote_staging` +
   `advance_watermark` → `drop_staging` → `row_count_source_vs_landed` DQ →
   `finish_table_run` with counts and watermark start/end (or SKIPPED with a reason, or
   FAILED with a classified, redacted error).
4. `finish_pipeline_run` rolls everything up.

### The landing contract (enforced by `tests/data-quality/raw/01_lp_check_metadata_col.sql`)
Every raw table must have `_batch_id` (text, NOT NULL — the `table_runs.table_run_id`
UUID, giving row-level lineage back to the run) and `_loaded_at` (timestamptz, NOT NULL,
not in the future, fresh within 24 h). Incremental loads **append** to raw (raw is
history); the staging layer dedupes by business key.

---

## 9. Tests — the data-quality gate

There are **no Python unit tests**. All testing is SQL data-quality procedures executed
against the warehouse, one suite per layer:

```
tests/data-quality/
├── raw/        10 tests + 00_master_raw_tests.sql
├── staging/    10 tests + 00_master_staging_tests.sql
├── analytics/ 13 tests + 00_master_analytics_tests.sql
└── marts/     10 tests + 00_master_marts_tests.sql
```

Each test file creates one `audit.dq_<layer>_<check>` procedure that:
1. inserts a row into `audit.dq_run`,
2. inserts one `audit.dq_violation` per bad row/message it finds,
3. updates the run with `violation_count` and PASS/FAIL, and
4. raises on failure (fail-fast for the master procedure; each test COMMITs its own
   audit rows first, so the cause survives the rollback).

Check catalogue (raw/staging/marts; analytics adds `11_date_key_integrity`,
`12_derived_attributes`, `13_reconciliation`):

| # | Check | What it proves |
|---|---|---|
| 01 | metadata_col | `_batch_id` / `_loaded_at` present, NOT NULL, `_loaded_at` timestamptz, not future, fresh (24 h) |
| 02 | primary_keys | PK/unique columns are non-null and unique |
| 03 | bad_dates | no NULL/impossible/future dates in date columns |
| 04 | orphan_rows | every FK has a parent row (e.g. accounts → customers) |
| 05 | business_rules | domain rules (amounts ≥ 0, valid statuses, plausible rates…) |
| 06 | numeric_ranges | numeric columns inside agreed min/max bands |
| 07 | schema_contract | columns and types match the expected contract |
| 08 | completeness | no unexpected NULLs / coverage thresholds met |
| 09 | duplicate_rows | no duplicate business keys or whole-row duplicates |
| 10 | value_domains | categorical values inside the allowed domain |

How they run:

```bash
python scripts/run_raw_tests.py            # discover, CREATE OR REPLACE, CALL each test
python scripts/run_raw_tests.py --only 09  # one test
python scripts/run_raw_tests.py --master   # CALL audit.dq_master_raw_tests() (all in order)
```

The runner (`run_raw_tests.py` and its three clones) autocommits, shows a rich progress
bar and summary, prints the latest `audit.v_dq_latest` row per test, and exits non-zero on
any failure — that non-zero exit is the gate that blocks publish in a scheduler.

---

## 10. Configuration — `.env`

Loaded once by `config.py`. See `.env.example` for the full annotated list:

| Group | Key variables |
|---|---|
| PostgreSQL | `PG_HOST/PG_PORT/PG_DB/PG_USER/PG_PASS` (warehouse `banking_delta`) |
| MySQL | `MYSQL_HOST/PORT/USER/PASSWORD/DB`, `MYSQL_SERVER_TZ`, `MYSQL_SSL_MODE` |
| MongoDB | `MONGO_URI`, `MONGO_DB_NAME`, `MONGO_TIMEOUT_MS`, `MONGO_SAMPLE_SIZE` |
| Databricks | `DATABRICKS_HOST/TOKEN/HTTP_PATH/CATALOG`, `DATABRICKS_SCHEMA_PUBLIC`, `DATABRICKS_MARTS_SCHEMA`, `DATABRICKS_FETCH_ROWS` |
| Spark | `SPARK_DRIVER_MEMORY`, `SPARK_SHUFFLE_PARTITIONS` |
| Extract | `EXTRACT_PARALLEL` |
| Publish | `PUBLISH_WORKERS`, `PUBLISH_WORKER_MIN_ROWS`, `PUBLISH_FETCH_SIZE`, `PUBLISH_MAX_PARAMS` |
| Airflow | `AIRFLOW_HOST/PORT/...`, `AIRFLOW__CORE__FERNET_KEY`, `AIRFLOW_CTX_*` (read by the runner) |
| Alerts | `ALERT_EMAIL_*`, `SMTP_*`, `AIRFLOW__SMTP__*` |
| Misc | `ENVIRONMENT`, `LOG_LEVEL`, `TIMEZONE`, `PROJECT_ROOT` (override for Airflow) |

---

## 11. Git, hooks and conventions

- **Branching**: short-lived `feature/*`, `fix/*`, `chore/*`, `docs/*`; one concern per
  branch; Conventional Commits `type(scope): summary`; open a PR and stop (no self-merge,
  no force-push).
- **`.githooks/`** (enable with `git config core.hooksPath .githooks`): `commit-msg`
  enforces the Conventional Commit format; `pre-commit` refuses to commit secrets
  (`.env`, `*.pem`, `*.key`, `id_rsa`) and runs `ruff check` + `ruff format --check` on
  staged Python files.
- **`.pre-commit-config.yaml`**: standard hygiene hooks, ruff (v0.12.0, matches CI),
  sqlfluff (postgres dialect, `sql/` + `tests/`), conventional-commits.
- **Code standards** (from `AGENTS.md`): PEP 8 + ruff + type hints everywhere; `Decimal`
  for money; timezone-aware UTC datetimes; `pathlib`; project logger only; specific
  exceptions (no bare `except`); SQL: uppercase keywords, `snake_case`, explicit column
  lists, `NUMERIC(18,2)` for money, timestamptz for times, procedures never COMMIT
  internally (except the DQ tests, which commit their audit rows on purpose).
- **Never**: commit `.env`/tokens, write to Databricks `public`, edit a merged migration,
  use `float` for money, weaken a test to get CI green.

---

## 12. Who-calls-whom map (quick reference)

```
scripts/run_jobs.py
  └─ subprocess: src/jobs/extract_mongo.py | extract_databricks.py | extract_mysql.py
       └─ utils/extract_runner.run_source(Source)
            ├─ utils/audit        (pipeline/table runs, DQ, extract_watermarks)
            ├─ utils/session      (Spark singleton, pg_transaction)
            ├─ utils/engine       (pre-flight + jar cache + SparkSession)
            └─ utils/spark_io     (read source → raw._stg_* → raw.*)

scripts/seed_watermarks.py → utils/audit.seed_watermark + utils/spark_io.*_max_watermark

psql: sql/staging/00_master_load.sql   → CALL staging.sp_load_all()
        └─ staging.sp_load_<table>_scd1  (raw.* → staging.*, audit.etl_watermarks)
psql: sql/analytics/00_master_load.sql → CALL analytics.sp_load_all()
        └─ analytics.sp_load_dim_*/fact_*  (staging.* → analytics.*)
psql: sql/marts/00_master_load.sql     → CALL marts.sp_load_all()
        └─ marts.sp_load_mart_*           (analytics.* → marts.*)

src/jobs/publish_marts.py → marts.mart_* → Parquet → Databricks volume → MERGE INTO Delta

scripts/run_{raw,staging,analytics,marts}_tests.py
  └─ tests/data-quality/<layer>/*.sql → audit.dq_run / audit.dq_violation / audit.v_dq_latest
```

---

## 13. Gotchas worth knowing

- **Landing is PostgreSQL, not files.** Raw, staging, analytics and marts all live in the
  warehouse DB. Parquet appears only as (a) the local scratch file for Databricks reads and
  (b) the marts→Databricks publish path.
- **`_batch_id`, not `_run_id`.** The landing contract columns are `_batch_id`
  (table-run UUID) and `_loaded_at` (timestamptz). AGENTS.md examples that mention
  `_run_id`/`etl.sp_*` are aspirational; the code uses `_batch_id` and
  `staging/analytics/marts.sp_load_*`.
- **Mongo date fields are strings.** `created_at`/`loaded_at`/`txn_date` are ISO strings
  in Mongo; `cast_temporal` fixes them at landing, which is why the Mongo watermark must
  be `_id` (ObjectId) and not a date field.
- **Databricks watermarks are normalized to naive UTC text.** The SQL connector returns
  tz-aware datetimes; `databricks_max_watermark` strips the offset so the value survives
  `_norm_ts` and can round-trip through `audit.extract_watermarks`.
- **The two watermark tables are per-layer on purpose.** Extracts advance
  `audit.extract_watermarks`; staging procedures advance `audit.etl_watermarks`. Sharing
  one row would crash on `+05:30` text and break `watermark_strategy='objectid'`.
- **Incremental raw appends.** Raw keeps history; duplicate boundary rows are expected and
  are collapsed by the staging layer's `ROW_NUMBER()` dedupe.
- **First incremental run of a new table**: seed with `python scripts/seed_watermarks.py`
  first, or the run will re-land the whole table as an append.
- **`03_register_sources.sql` cannot flip existing rows** (`ON CONFLICT DO NOTHING`) —
  use `05_switch_mongo_databricks_incremental.sql` on an already-seeded database.
- **Windows-aware**: single-file Parquet reads (no Hadoop dir listing), Ivy cache inside
  the project, `.bat`-friendly paths everywhere.

---

## 14. `main.py` — the full-pipeline runner

`main.py` runs the whole daily pipeline as **9 gated steps in order**, stopping at the
first failing step so nothing downstream sees half-loaded data (override with
`--keep-going`). It is the Windows-friendly single entry point that replaces the manual
`psql`/`python` sequence in §2.

```
raw-inject -> raw-tests -> staging-load -> staging-tests -> analytics-load
  -> analytics-tests -> marts-load -> marts-tests -> publish
```

| Step | Kind | Runs |
|---|---|---|
| raw-inject | script | `scripts/run_jobs.py` (mongo → databricks → mysql) |
| raw-tests | script | `scripts/run_raw_tests.py` |
| staging-load | SQL | `sql/staging/00_master_load.sql`, then `CALL staging.sp_load_all()` |
| staging-tests | script | `scripts/run_staging_tests.py` |
| analytics-load | SQL | `sql/analytics/00_master_load.sql`, then `CALL analytics.sp_load_all()` |
| analytics-tests | script | `scripts/run_analytics_tests.py` |
| marts-load | SQL | `sql/marts/00_master_load.sql`, then `CALL marts.sp_load_all()` |
| marts-tests | script | `scripts/run_marts_tests.py` |
| publish | script | `src/jobs/publish_marts.py` |

- The three `*-load` steps read the schema's `00_master_load.sql`, execute it (so the
  procedures are refreshed) and then `CALL <schema>.sp_load_all()` on one connection; PG
  `NOTICE` output is echoed as dim text. Exit code is non-zero if any executed step failed.
- Flags: `--list`, `--from <step>`, `--only <step>` (repeatable), `--keep-going`.
- Each child script runs in a subprocess rooted at the repo, so exactly one Spark/JVM
  lives at a time.
- `main.py` pins UTF-8 on `sys.stdout`/`sys.stderr` (`errors="replace"`) before building
  the Rich `Console(legacy_windows=False)`, because legacy Windows consoles default to
  cp1252 and choke on the `·` / `—` glyphs in the report.

---

## 15. Session log — bug fixes and open items

This section records a debugging/verification session that made the full
`python main.py` run green (all 9 steps SUCCESS, every DQ gate passing) on a Windows
dev box. It documents **what was changed, why, and what is still open** so the next
agent does not re-derive it. No commits were made from this session unless stated.

### 15.1 Fixes applied

| Area | Problem | Fix |
|---|---|---|
| `.env` parsing | inline `#` comments on the same line as a value corrupted that value (e.g. the Spark jars list) | moved inline comments onto their own lines |
| `src/utils/engine.py` | a `#` comment inside `SPARK_JARS_PACKAGES` was passed to Maven, breaking jar resolution | added `_COORD_RE` + `_clean_packages()` to strip `#` comments and fall back to auto-resolving coordinates from the installed PySpark/Scala version |
| `main.py` console | Windows console (cp1252) crashed on `·` / `—` glyphs in the Rich report | reconfigure `sys.stdout`/`sys.stderr` to UTF-8 (`errors="replace"`) before `Console(legacy_windows=False)` |
| `src/utils/spark_io.py` `_dbx_where` | Databricks incremental predicate used `>= start`, so a boundary row was re-landed every run and duplicated (all batch rows share one `created_at`) | changed the lower bound to `> start` |
| `tests/data-quality/raw/{01,02,03,08,09,10}_*.sql` | transient Spark staging tables `raw._stg_*` were picked up by schema/contract checks and failed the gate | added `AND c.relname NOT LIKE '\_stg\_%'` to the `pg_class` filters |
| `tests/data-quality/staging/10_lp_check_value_domains.sql` | the `staging.scd1_history.table_name` allowed set did not include the `analytics.*` names, so analytics history rows failed the staging domain check | extended the allowed set (all `analytics.dim_*` / `analytics.fact_*` names) |
| `src/utils/audit.py` | `SKIPPED` table runs logged only `extracted=None landed=None`; the real reason lived only in `table_runs.execution_metadata.skip_reason` | added a follow-up `logger.info("[%s] skipped: %s", …)` when `run.metadata["skip_reason"]` is present |
| mart publish | `mart_support_performance` was 193 rows short in Databricks vs PostgreSQL | one-off `--full` republish; see 15.3 for the root cause and the recommended durable fix |

### 15.2 Root causes worth remembering

- **Databricks boundary duplication.** All rows in a batch share a single
  `created_at` timestamp. With a `>= start` predicate the whole "current" batch was
  re-read on the next run and appended again. `>` fixes it but means a genuinely
  re-emitted row with an unchanged timestamp is *not* picked up — the source must
  advance `created_at` for new/changed rows.
- **Staging/analytics DQ vs. source data.** Staging intentionally NULLs
  `date_resolved` when it falls outside `[2000-01-01, CURRENT_DATE]` (future dates), and
  the analytics DQ requires `date_resolved` / `resolution_days` NOT NULL. So a source
  ticket with a future resolution date looks correct in the source but fails analytics
  DQ. Seeded test data must therefore use **past** resolution dates.
- **Mongo seed hygiene.** Test tickets/transactions need unique sequential business IDs
  (`ticket_id`, `card_txn_id`), valid categorical domains, and populated
  `date_resolved`. Bad earlier seeds (`NEW%` IDs) had to be deleted from raw (by
  `_batch_id`) *and* from Mongo before a clean run.

### 15.3 Open items (decisions, not yet changed)

1. **Publish lookback gap (recurring).** `src/jobs/publish_marts.py` only re-sends
   `watermark >= last watermark in the Delta target`; with `PUBLISH_LOOKBACK_MONTHS=0`
   the default, late-arriving/edited rows in older months never get republished. This is
   what caused the `mart_support_performance` 193-row gap across months 2024-05 → 2026-05
   (4–15 rows per month). Durable fix: set a non-zero `PUBLISH_LOOKBACK_MONTHS` (e.g. 3)
   for the date-windowed marts and/or schedule a periodic `--full` republish. **Not
   applied.**
2. **Timezone off-by-offset bug (needs approval).** The PG sessions resolve to
   `Asia/Calcutta`, while Spark's JVM is pinned UTC (`engine.py` sets
   `-Duser.timezone=UTC`). The PG JDBC URL in `pg_jdbc()` sets no timezone, so Postgres
   interprets Spark's naive UTC timestamp strings as IST: `raw.*._loaded_at`,
   staging `source_loaded_at` and the staging watermarks are stored **5.5 h earlier than
   the real instant** (displayed with a misleading `+05:30`). Harmless for the 24 h
   freshness gate, but wrong for any "compare to real time" logic. Fix: pin `TimeZone=UTC`
   on the PG JDBC URL and `SET TIME ZONE 'UTC'` / `options=-c timezone=UTC` on the psycopg
   connections. This changes how every raw/staging timestamp and watermark is stored, so it
   is an **ask-first** change; also decide whether to backfill existing rows or fix
   forward. **Not applied.**
3. **Analytics band drift (recurring).** `age_band` / `tenure_band` / `account_age_band`
   are derived from `CURRENT_DATE`, so they drift at date boundaries. The daily
   `analytics-load` step runs incremental (`sp_load_all()` without `p_force_full`), so the
   drift will recur and can fail the analytics DQ on a later date. `p_force_full => TRUE`
   refreshes them. Decision needed: force-refresh the derived-attribute dims on every
   daily load, or move the bands to a date-independent definition. **Not changed.**

### 15.4 Confirmed working as designed (not bugs)

- `mart_customer_360` has 60001 rows and `mart_branch_performance` 151: the extra row is
  the intentional `customer_key = -1` / `branch_key = -1` "Unknown" member, so facts never
  carry a broken key (`sql/analytics/01_dim_customer.sql`, `03_dim_branch.sql`).
- `mart_customer_360`, `mart_branch_performance` and `mart_loan_portfolio` republish every
  row each run: they key on `mart_refreshed_at`, which a full rebuild always advances.
  Publish is a MERGE/upsert, so totals still reconcile.
- MySQL tables being full-loaded every run and landing "unchanged" in staging is correct;
  only Mongo and Databricks are incremental.

### 15.5 Verification status

- Full `python main.py` run: **9/9 steps SUCCESS**; gates raw 10/10, staging 10/10,
  analytics 13/13, marts 11/11; all `SKIPPED` reasons resolved to
  `no new data past the watermark` (expected on a same-day second run).
- `make lint` / `make test` could not be run: the project `pyproject.toml` has no dev
  dependencies installed on this box, and there are no Python unit tests (§9 is the test
  suite). This remains open for a properly provisioned environment.

---

## 16. Dashboard — Streamlit + Plotly over the Databricks marts

`dashboard/` is a standalone Streamlit app that reads the **published Databricks `marts`
schema live** through a SQL warehouse. It is completely decoupled from the pipeline: no
extracts, no cached copies, no writes — every chart is a plain `SELECT` against Delta. It
only sees data that `src/jobs/publish_marts.py` (§6) has already pushed.

### 16.1 Pages

| Page | File | Mart | Focus |
|---|---|---|---|
| Executive Overview | `app.py` | `mart_kpi_monthly` | KPI cards, dual-axis lines, area, diverging MoM bars |
| KPI Explorer | `pages/KPI.py` | `mart_kpi_monthly` | Per-metric small multiples, quarterly rollup, MoM bars, full table |
| Customers | `pages/customers.py` | `mart_customer_360` | Segment treemap, gender/credit donuts, income vs exposure scatter, top-activity bars |
| Loans | `pages/loans.py` | `mart_loan_portfolio` | Mix treemap, vintage lines, band bars, interest-vs-late scatter |
| Cards | `pages/cards.py` | `mart_card_fraud` | Spend-vs-fraud lines, fraud treemap, tier×merchant heatmaps |
| Branches | `pages/branches.py` | `mart_branch_performance` | League bars, region treemap, efficiency scatters |

`mart_monthly_transactions` and `mart_support_performance` have loaders in
`helpers/marts.py` but no dedicated page yet.

### 16.2 Layout

```
dashboard/
├── app.py                     # Executive overview (Streamlit's implicit home page)
├── pages/                     # KPI.py, customers.py, loans.py, cards.py, branches.py
├── lib/
│   ├── db.py                  # Databricks SQL connection + cached queries (+ ping/health)
│   ├── charts.py              # Plotly builders: line, bars, area, donut, treemap, scatter, heatmap, funnel, diverging_mom
│   └── filter.py              # Sidebar controls + dataframe filter helpers
├── helpers/
│   ├── marts.py               # Typed loaders, one per marts table
│   ├── components.py          # Page chrome: header, KPI cards, section, chart, table, footer, auto-refresh fragment
│   ├── theme.py               # Brand palette + ₹ / % / int / date formatting + SI tick labels
│   └── plotly_template.py     # Shared "banking" Plotly template
├── .streamlit/                # config.toml (committed), secrets.toml (git-ignored)
├── requirements.txt           # streamlit, pandas, plotly, databricks-sql-connector
├── Dockerfile                 # python:3.13-slim, healthcheck, entrypoint on :8501
└── README.md
```

### 16.3 Connection and caching (`lib/db.py`)

- Config comes from `.streamlit/secrets.toml` first, then environment variables:
  `DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_TOKEN`, `DATABRICKS_CATALOG`
  (default `main`), `DATABRICKS_MARTS_SCHEMA` (default `marts`) — `setting()` /
  `require_setting()`.
- One connection is opened and reused across reruns (`@st.cache_resource get_connection`);
  queries are cached for **5 minutes** (`DEFAULT_TTL_SECONDS`) via `@st.cache_data run_query`.
- `run_query` prefers Arrow (`fetchall_arrow().to_pandas()`), falls back to row fetch, and
  on a Databricks error shows `st.error` and stops the page. `ping()` is a health check;
  `last_success_at()` feeds the "Live" badge; `clear_cache()` backs the **Refresh now**
  button.
- Every loader runs `SELECT * FROM <catalog>.<marts_schema>.<table>` (no `WHERE`), then
  `_cast_decimals` converts the connector's `Decimal` columns to float64 for pandas/Plotly.
  So all filtering happens **in the browser**, not in SQL.

### 16.4 UI behaviour

- Each page wraps its live body in `@auto_fragment` (`st.fragment(run_every=interval)`), so
  only that section re-queries on the sidebar auto-refresh interval (Off / 1 / 5 / 15 min).
- `render_sidebar()` draws the global controls (auto-refresh selector, **Refresh now**,
  cache-age caption) and every page adds its own filters below it: month-range sliders and
  categorical multiselects (`multiselect_all` returns `None` while empty = "no filter").
- `helpers/components.py` provides the shared chrome: `page_header`, `live_badge`,
  `kpi_cards` (`Kpi` dataclass), `section`, `chart`/`two_charts`, `table` (typed column
  config with ₹ / % / int formats), and `footer` (lineage note).
- `helpers/theme.py` + `helpers/plotly_template.py` give every page the same palette,
  `₹` lakh/crore formatting and a registered default Plotly template.

### 16.5 Run it

```bash
cd dashboard
python -m venv .venv && .venv\Scripts\activate      # Windows (or source .venv/bin/activate)
pip install -r requirements.txt
cp .streamlit/secrets.toml.example .streamlit/secrets.toml   # then fill in real values
streamlit run app.py
```

Docker: `docker build -t banking-dashboard .` then
`docker run -p 8501:8501 banking-dashboard` (pass secrets as env vars or mount the secrets
file). `.streamlit/secrets.toml` is git-ignored; only the `.example` is committed.

### 16.6 Dashboard gotchas

- **Read-only and post-publish.** The dashboard reflects only what has been published to
  Databricks. Because `publish_marts.py` is incremental (§15.3), corrections in older
  months can be missing from the dashboard until a `--full` republish or a lookback is
  configured — the dashboard will faithfully show the stale number.
- **The derived-band drift (§15.3) is visible here too.** Customer/branch age bands and the
  KPI monthly rows are computed at pipeline time, so the dashboard shows whatever the last
  load wrote; it never recomputes bands.
- **`SELECT *` loaders.** The marts schema must match the columns each page expects; a
  newly added mart column is harmless, but a renamed/removed one can blank a chart.
- **No auth in the app.** Access control (if any) is expected at the network/proxy layer;
  the app itself only needs a token with read on the marts schema.
