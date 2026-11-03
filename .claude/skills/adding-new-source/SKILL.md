---
name: adding-new-source
description: Land a new table from a source system (MySQL, MongoDB, Databricks) into the raw layer.
trigger: adding a new source, landing a new table, new extractor, new source table
---

# Adding a New Source Table

This workflow lands a new table/collection from a source system into the `raw`
layer. The pipeline is **registry-driven**: extractors read `contracts/registry.json`
(and `audit.source_tables`), so most new tables need zero extractor code.

## Procedure

1. **Register the table (SQL first, then mirror)**
   - Add the table to `sql/scripts/03_register_sources.sql` (insert into
     `audit.source_tables`; re-runs are `ON CONFLICT DO NOTHING`).
   - Mirror the same entry in `contracts/registry.json`: `source_schema`,
     `source_table`, `target_schema/target_table`, `business_key`,
     `load_strategy` (`full` or `incremental`), `incremental_column`,
     `watermark_strategy`.
   - MySQL tables are `full`; MongoDB/Databricks are `incremental`
     (`objectid` / `timestamp` watermarks).

2. **Add the column contract**
   - Create `contracts/{mysql|mongodb|databricks}/<table>.json` with one entry per
     column (`name`, `type`, `nullable`, `key` for the business key). Types are
     Postgres types: money is `numeric(18,2)`, times `timestamptz`, never `double
     precision` for money.
   - Validate with `make contracts` (checked against `source-table.schema.json`).

3. **Do NOT create `raw.<table>` by hand**
   - The landing job creates it automatically on first run
     (`CREATE TABLE ... LIKE raw._stg_<table>`, then TRUNCATE/append per
     `load_strategy`), carrying `_batch_id text NOT NULL` and
     `_loaded_at timestamptz NOT NULL`.
   - No migration file is needed; `sql/` contains numbered bootstrap and load
     procedures only.

4. **Watermarks (incremental tables only)**
   - After switching a table to `incremental`, seed it so the first run does not
     re-land the whole collection: `python scripts/seed_watermarks.py --dry-run`
     then `python scripts/seed_watermarks.py`.
   - Never seed MySQL (it stays on full loads).

5. **Add/extend DQ config for the new table**
   - The raw suites hardcode per-table JSONB config — add the table where its
     columns apply: `tests/data-quality/raw/02_lp_check_primary_keys.sql`
     (`v_key_overrides`), `07_lp_check_schema_contract.sql`,
     `08_lp_check_completeness.sql` (expected row counts),
     `10_lp_check_value_domains.sql`, plus any `06` numeric ranges.

6. **Optional: refresh the shipped CSV snapshot**
   - `python scripts/export_raw_csv.py --sources <mysql|mongo|databricks>`
     rewrites `data/raw/<folder>/<table>.csv.gz` so `make load-raw-csv` stays a
     working bootstrap for clones without source access.

7. **Verify**
   - `make contracts && make sql-lint`
   - `python scripts/run_jobs.py --sources <mysql|mongo|databricks>` (or `make run-jobs`)
   - `SELECT count(*) FROM raw.<table>;` then `make dq-raw`
   - `make test` (smoke contracts assert registry/contract consistency)

## Done Checklist

- [ ] Row in `sql/scripts/03_register_sources.sql` **and** `contracts/registry.json`.
- [ ] Column contract created; `make contracts` passes.
- [ ] First extract lands rows in `raw.<table>` with `_batch_id`/`_loaded_at`.
- [ ] Incremental tables seeded with `scripts/seed_watermarks.py`.
- [ ] Raw DQ configs updated; `make dq-raw` passes.
- [ ] `make lint` and `make test` pass.
