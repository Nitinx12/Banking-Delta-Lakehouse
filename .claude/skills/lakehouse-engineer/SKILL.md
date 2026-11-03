---
name: lakehouse-engineer
description: "Use this skill when adding a new table or modifying existing pipeline logic across the Medallion layers"
trigger: "add table, modify procedure, new source, update mart, change landing"
---

# Lakehouse Engineer Skill

End-to-end flow for adding or modifying tables across the Medallion layers
(raw → staging → analytics → marts), respecting layer ownership from
`ARCHITECTURE.md` (each schema has exactly one writer).

## Workflow for Table Modifications

1. **Contract & registry (the schema source of truth)**
   - Add/extend the entry in `sql/scripts/03_register_sources.sql` and mirror it
     in `contracts/registry.json`; add `contracts/<source>/<table>.json` with
     Postgres column types (money `NUMERIC(18,2)`, times `timestamptz`).
   - Validate with `make contracts`. There are **no Flyway `V<n>__` files** here —
     SQL lives in numbered files under `sql/<area>/`, next free number, and
     applied scripts are never rewritten in a way that breaks idempotency.

2. **Landing (extractors are registry-driven)**
   - `scripts/run_jobs.py` → `src/utils/spark_io.py` `read_mysql`/`read_mongo`/
     `read_databricks` pick up new registry entries automatically; only add code
     for a genuinely new source system.
   - `raw.<table>` is created on first run by `promote_staging`
     (`_batch_id`, `_loaded_at` NOT NULL). Every load must be safe to run twice;
     incremental tables advance watermarks only inside the load transaction
     (seed new incremental tables with `scripts/seed_watermarks.py`).

3. **Staging procedure**
   - `sql/staging/NN_sp_load_<table>_scd1.sql` → `staging.sp_load_<table>_scd1`
     (clean, cast, hash for change detection), `OUT` counts, no internal
     `COMMIT`/`ROLLBACK`, advisory lock.
   - Register the `CALL` in `sql/staging/00_master_load.sql` (invoked via
     `staging.sp_load_all()`).

4. **Analytics / marts procedures**
   - `analytics.sp_load_dim_<target>` / `analytics.sp_load_fact_<target>` in
     `sql/analytics/NN_<target>.sql`; SCD2 dims carry `effective_to`,
     `is_current`, `_hash_t2`. Marts: `marts.sp_load_mart_<name>` — see the
     `adding-new-mart` skill.
   - Register every `CALL` in the layer's `00_master_load.sql` in dependency
     order.

5. **Data quality (SQL suites, not Great Expectations)**
   - Add/extend checks under `tests/data-quality/<layer>/` (procedures
     `audit.dq_<layer>_*`, next free `NN_`, registered in that layer's
     `00_master_*_tests.sql`). Critical failures block publish — never weaken a
     check to go green.
   - Run: `make dq-raw|dq-staging|dq-analytics|dq-marts` or all with `make dq`.

6. **Optional CSV bootstrap path**
   - `make export-raw-csv` refreshes `data/raw/*.csv.gz` so clones without source
     access can run `make load-raw-csv` into `raw`.

## References

- **Architecture / ownership / naming**: `ARCHITECTURE.md` (wins on design)
- **Agent rules and permissions**: `AGENTS.md`
- **Detailed skills**: `adding-new-source`, `adding-new-mart`, `writing-dq-tests`

## Done Checklist

- [ ] Registry + column contract updated; `make contracts` passes.
- [ ] Layer procedures created, registered in `00_master_load.sql`, schema-qualified names
      (`staging.sp_*`, `analytics.sp_*`, `marts.sp_load_mart_*`).
- [ ] No `float` for money; `NUMERIC(18,2)` used; no internal `COMMIT`/`ROLLBACK`;
      `OUT` counts present.
- [ ] DQ suites extended for the new columns/tables; `make dq` passes.
- [ ] `make lint` and `make test` pass.
