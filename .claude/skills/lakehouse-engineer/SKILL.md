---
name: lakehouse-engineer
description: "Use this skill when adding a new table or modifying existing pipeline logic across the Medallion layers"
trigger: "add table, modify procedure, new source, update mart"
---

# Lakehouse Engineer Skill

This skill handles the end-to-end flow of adding or modifying tables within the Medallion architecture (Raw $\rightarrow$ Staging $\rightarrow$ Core/Analytics $\rightarrow$ Marts).

## Workflow for Table Modifications

Follow these steps sequentially to ensure data consistency and pipeline integrity:

1. **Contract & Schema Update**
   - Define the source schema.
   - Create/update Flyway migration files (`V<n>__name.sql`) for the target tables in PostgreSQL.
   - Ensure money is `NUMERIC(18,2)` and times are `timestamptz`.

2. **Extractor Verification**
   - Check the PySpark extractor logic.
   - Ensure the new table is included in the landing process (MySQL/MongoDB $\rightarrow$ PostgreSQL landing).
   - Verify idempotency (tagging with `_run_id`).

3. **Staging Procedure Implementation**
   - Create or modify the staging procedure (`etl.sp_load_stg_<target>`).
   - Implement data cleaning, casting, and hashing for change detection.
   - Use `OUT` parameters for row counts.

4. **Analytics/Mart Procedure Implementation**
   - Implement the Core/Mart load procedure (`etl.sp_load_dim_<target>` or `etl.sp_load_fact_<target>`).
   - Handle SCD Type 2 logic where applicable (effective dates, `is_current`).
   - Ensure procedures take advisory locks and do not contain internal `COMMIT`/`ROLLBACK`.

5. **Data Quality (DQ) Tests**
   - Define Great Expectations suites or SQL-based validation tests.
   - Ensure critical DQ failures block the publish step.

## References
- **Architecture**: See `ARCHITECTURE.md` for layer definitions and naming conventions.
- **Agent Rules**: See `AGENTS.md` for coding standards (Python/SQL) and permissions.

## Done Checklist
- [ ] Flyway migrations created and tested.
- [ ] PySpark extractor updated and verified.
- [ ] Staging and Core/Mart procedures follow `etl.sp_<action>_<target>` naming.
- [ ] Procedures use `OUT` parameters for counts.
- [ ] No `float` used for money; `NUMERIC(18,2)` used instead.
- [ ] DQ tests implemented and passing.
- [ ] `make lint` and `make test` pass.
