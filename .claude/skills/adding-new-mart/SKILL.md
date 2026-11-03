---
name: adding-new-mart
description: Create a new business table in the marts layer and publish it to Databricks Delta.
trigger: adding a new mart, creating a business table, publish mart, new mart table
---

# Adding a New Mart

This workflow creates a new business mart in the `marts` layer and gets it
published to Databricks Delta. Publishing is **auto-discovered** — no publish
code changes are needed.

## Procedure

1. **Design from `analytics`**
   - Sources are the dims/facts in `analytics` (`dim_*`, `fact_*`). Check
     `sql/analytics/` for what exists and `ARCHITECTURE.md` for layer ownership.
   - Decide the grain and the composite key (business keys become DQ config).

2. **Write the mart file**
   - New numbered file `sql/marts/NN_mart_<name>.sql` (next free number), procedure
     `marts.sp_load_mart_<name>`.
   - Copy the structure of an existing file (e.g. `sql/marts/04_mart_loan_portfolio.sql`):
     dependency guards (`IF to_regclass(...) IS NULL THEN RAISE EXCEPTION`),
     `DROP PROCEDURE IF EXISTS marts.sp_load_mart_<name>(UUID, TEXT, BOOLEAN, UUID);`
     before `CREATE OR REPLACE`, then the procedure with signature
     `(p_table_run_id UUID, p_source_batch_id TEXT, p_force_full BOOLEAN, p_pipeline_run_id UUID)`.
   - Conventions: money `NUMERIC(18,2)`, times `timestamptz`, no `COMMIT`/
     `ROLLBACK`, `OUT` counts, audit seeding so manual runs still record
     `audit.table_runs`, full-refresh idempotent (`TRUNCATE`+`INSERT` or `ON
     CONFLICT` upsert).
   - Table name: `marts.mart_<name>` (CREATE TABLE IF NOT EXISTS inside the file).

3. **Register the CALL**
   - Add one `CALL marts.sp_load_mart_<name>(...);` at the marked place in
     `sql/marts/00_master_load.sql` (`>>> ADD NEW MARTS HERE <<<`), respecting
     dependencies between marts.

4. **Extend the marts DQ suite**
   - Add the mart to the JSONB config of `tests/data-quality/marts/`:
     `02` (primary/composite key), `04` (orphans vs analytics parents),
     `05` (business rules), `07` (schema contract column types),
     `08` (completeness/row counts), `10` (value domains) — wherever the new
     columns apply. Checks are enforced by `marts.sp_load_all` gate before publish.

5. **Run and verify locally**
   - `make marts` (CALLs `marts.sp_load_all()`), then `make dq-marts`.
   - Single mart: `python main.py --only marts-load`, or
     `psql ... -c 'CALL marts.sp_load_mart_<name>();'`.

6. **Publish**
   - `src/jobs/publish_marts.py` discovers every table in the `marts` schema
     automatically (`_discover`), so there is **no list to edit**.
   - Smoke it for one table first:
     `python src/jobs/publish_marts.py --tables mart_<name> --full`, then
     `make publish` for the normal incremental path.
   - Verify the Delta table in the Databricks `marts` schema.

7. **Docs**
   - If this adds a published mart, refresh the metrics table in `README.md`
     ("Marts published", "DQ checks across layers").

## Done Checklist

- [ ] `sql/marts/NN_mart_<name>.sql` follows an existing mart file's structure.
- [ ] `CALL` registered in `00_master_load.sql` at the marker.
- [ ] `make marts && make dq-marts` pass.
- [ ] `make publish` lands the table in Databricks `marts` (auto-discovered).
- [ ] README metrics and `docs/` updated if counts changed.
- [ ] `make lint` and `make test` pass.
