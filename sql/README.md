# SQL — Banking-Delta

PostgreSQL SQL for the `banking_delta` warehouse: bootstrap scripts, stored
procedures and read-only exploration queries. The pipeline runs the same files
(`main.py` → `CALL <schema>.sp_load_all`); Airflow owns no logic of its own.

## Layout

| Path | Contents | In the daily pipeline |
| --- | --- | --- |
| `scripts/` | `00`–`06`: create the database, schemas, audit tables, source registry, watermarks | one-time bootstrap |
| `staging/` | `sp_load_*_scd1` procedures + `00_master_load` | yes |
| `analytics/` | `sp_load_dim_*` / `sp_load_fact_*` + `00_master_load` | yes |
| `marts/` | `sp_load_mart_*` + `00_master_load` | yes |
| `raw/` | `explore_raw_*` queries | no — exploration only |
| `metadata/` | `list_*` catalog queries | no — exploration only |

`99_debug_*` files are developer helpers, never called by the pipeline.

## Run order

```text
scripts/00 → 01 → 02 → 03 → 04 → 05 → 06    bootstrap (once)
staging/00_master_load.sql                   CALL staging.sp_load_all()
analytics/00_master_load.sql                 CALL analytics.sp_load_all()
marts/00_master_load.sql                     CALL marts.sp_load_all()
```

Each `00_master_load.sql` defines `sp_load_all(p_force_full, p_pipeline_run_id)`
and calls every load in dependency order — parents first. Adding a table means one
`CALL` line in the marked slot. Every load is idempotent and safe to re-run with
the same input.

## Conventions

- Uppercase keywords, `snake_case` identifiers, explicit column lists (no `SELECT *`).
- Money is `NUMERIC(18,2)`; timestamps are `timestamptz` (UTC).
- Procedure names follow `etl.sp_<action>_<target>`; models are `dim_*`, `fact_*`, `mart_*`.
- A load procedure takes an advisory lock, writes audit rows, returns counts through
  `OUT` parameters, and never `COMMIT`s or `ROLLBACK`s.
- The DQ suites live in `tests/data-quality/{raw,staging,analytics,marts}/`, not here.

## Tooling

- `make sql-lint` — sqlfluff (postgres dialect) over `sql/` and `tests/`.
- `make sql-smoke` — applies the bootstrap and every procedure against a disposable
  Postgres (`ALLOW_SQL_SMOKE=1`). Never point it at the real warehouse.
