# SQL — Banking Delta Lakehouse

PostgreSQL SQL for the `banking_delta` warehouse: one-time bootstrap scripts, the
stored procedures that move data between layers, and read-only exploration
queries. The daily pipeline never runs these files directly — `main.py` and the
Airflow DAG apply them and then `CALL` the layer's master procedure.

## Layout

| Path | Contents | In the daily pipeline |
| --- | --- | --- |
| `scripts/` | `00`–`06`: create the database, schemas, audit tables, source registry, watermarks | one-time bootstrap |
| `staging/` | 10 `sp_load_*_scd1` procedures + `00_master_load` | yes |
| `analytics/` | 11 `sp_load_dim_*` / `sp_load_fact_*` procedures + `00_master_load` | yes |
| `marts/` | 7 `sp_load_mart_*` procedures + `00_master_load` | yes |
| `raw/` | `explore_raw_*` queries | no — exploration only |
| `metadata/` | `list_*` catalog queries | no — exploration only |

`99_debug_*` files are developer helpers and are never called by the pipeline.

Every `NN_*.sql` file in a layer does two things: it creates the target table and
indexes if missing, and it defines the load procedure with `CREATE OR REPLACE`.
Applying the file therefore installs the procedure; it does **not** execute it.
Execution is always a separate `CALL`.

## Bootstrap (one-time)

Run in numeric order. Each file is idempotent, so re-running is safe.

```text
scripts/00_create_database.sql     -- against the `postgres` maintenance DB
scripts/01_init_schemas.sql        -- against banking_delta
scripts/02_audit_tables.sql
scripts/03_register_sources.sql
scripts/04_dq_audit_tables.sql
scripts/05_switch_mongo_databricks_incremental.sql   -- optional, after first load
scripts/06_extract_watermarks.sql
```

`00` must be pointed at the `postgres` database because it creates
`banking_delta`. Every later script guards on `current_database() = 'banking_delta'`
and refuses to run anywhere else. `05` flips MongoDB and Databricks tables from
full to incremental extraction and is only needed once the tables exist.

`make sql-smoke` applies the bootstrap scripts (except the database-creation and
incremental-switch scripts) and every individual load file — but not the
`00_master_load` or `99_debug` files — to a disposable Postgres when
`ALLOW_SQL_SMOKE=1` is set.

## Daily workflow

```text
raw        landed by the pipeline (not SQL here)
staging    CALL staging.sp_load_all()
           -> DQ gate
analytics  CALL analytics.sp_load_all()
           -> DQ gate
marts      CALL marts.sp_load_all()
           -> DQ gate
publish    curated Delta tables to Databricks
```

Each layer's `00_master_load.sql` defines `sp_load_all(p_force_full, p_pipeline_run_id)`
and calls every load in dependency order — parents before children. Adding a table
means one `CALL` line in the marked slot of the layer's master file. The pipeline
runs layers in this order and stops on a failed gate.

## Calling a master procedure

```sql
-- normal incremental run
CALL staging.sp_load_all();

-- full reload of the layer (ignores watermarks)
CALL staging.sp_load_all(p_force_full => TRUE);

-- attach the run to an existing pipeline run so audit rows join up
CALL staging.sp_load_all(p_pipeline_run_id => '11111111-1111-1111-1111-111111111111');
```

Both parameters are optional. When `p_pipeline_run_id` is omitted the procedure
generates a UUID and seeds its own `audit.pipeline_runs` / `audit.table_runs` rows,
so a manual `CALL` still lands SUCCESS/FAILED audit entries. A `run_<timestamp>`
batch label is shared by every load in the call. The procedure never commits or
rolls back — the caller owns the transaction, and in `psql` that means the
statement auto-commits unless you wrap it in `BEGIN`.

The master file must exist before the call: it is what defines `sp_load_all`.
Apply it once (or every run, as `main.py` does) and then call it.

```bash
psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 \
  -f .\sql\staging\00_master_load.sql      # defines staging.sp_load_all
psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 \
  -c "CALL staging.sp_load_all();"          # runs every staging load
```

## Calling one load procedure

Use this to load a single table or to test a change without the whole layer.

```sql
CALL staging.sp_load_customers_scd1();

CALL staging.sp_load_customers_scd1(p_force_full => TRUE);

CALL staging.sp_load_customers_scd1(
    p_pipeline_run_id => '11111111-1111-1111-1111-111111111111'
);
```

Signatures are uniform across layers:

| Parameter | Type | Meaning |
| --- | --- | --- |
| `p_table_run_id` | UUID | audit key for this table run; generated if omitted |
| `p_source_batch_id` | TEXT | label for the source batch; `manual_<ts>` if omitted |
| `p_watermark_column` | TEXT | staging only; overrides the registered column |
| `p_force_full` | BOOLEAN | `TRUE` ignores the watermark and reloads everything |
| `p_pipeline_run_id` | UUID | links the run to the orchestrator's run |

Before doing anything each procedure checks that it is connected to
`banking_delta`, that the source table exists, and that the audit objects exist;
it raises rather than silently doing the wrong thing.

Watermark behaviour:

- The watermark lives in `audit.etl_watermarks` and advances **only on success**,
  to the max value processed in the slice.
- A `NULL` watermark (bootstrap) or `p_force_full => TRUE` loads the whole table.
- If the slice is empty the watermark is left unchanged.

Results are reported with `RAISE NOTICE` and written to `audit.table_runs`
(`rows_extracted`, `rows_landed`, watermark start/end, duration). On error the
procedure writes to `audit.pipeline_errors`, marks the run FAILED, and re-raises.

## Running a file by hand

Applying a file and calling it are two steps:

```bash
psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 \
  -f .\sql\staging\01_sp_load_customers_scd1.sql

psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 \
  -c "CALL staging.sp_load_customers_scd1();"
```

The first command installs/updates the procedure; the second executes it. Both are
safe to repeat.

## Conventions

- Uppercase keywords, `snake_case` identifiers, explicit column lists (no `SELECT *`).
- Money is `NUMERIC(18,2)`; timestamps are `timestamptz` (UTC).
- Procedures live in the layer schema: `staging.sp_load_*`, `analytics.sp_load_*`,
  `marts.sp_load_*`; models are `dim_*`, `fact_*`, `mart_*`.
- A load writes audit rows, never `COMMIT`s or `ROLLBACK`s, and leaves the
  transaction to the caller.
- The DQ suites live in `tests/data-quality/{raw,staging,analytics,marts}/`, not here.

## Tooling

- `make sql-lint` — sqlfluff (postgres dialect) over `sql/` and `tests/`.
- `make sql-smoke` — applies the bootstrap and every individual load file against a
  disposable Postgres (`ALLOW_SQL_SMOKE=1`). Never point it at the real warehouse.
