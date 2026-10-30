---
globs: ["sql/**/*.sql", "src/**/*.py"]
---
# API Design Rules

## SQL Naming
- **Procedures:** Use `etl.sp_<action>_<target>` (e.g., `staging.sp_load_customers_scd1`).
- **Tables:** 
    - Dimensions: `dim_*`
    - Facts: `fact_*`
    - Marts: `mart_*`
    - Staging: `stg_*` or source name.
- **Columns:** Use `_run_id`, `_batch_id`, `_loaded_at` for audit and lineage.

## Procedure Contracts
- **Transactions:** Procedures must never call `COMMIT` or `ROLLBACK` internally; they must take an advisory lock.
- **DQ Procedures:** SQL procedures in `tests/data-quality/` must `COMMIT` results before calling `RAISE` on failure to preserve the error record.
- **Outputs:** Return counts through `OUT` parameters.
