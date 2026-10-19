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
├── main.py                     # unused uv template stub ("Hello from banking!")
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
