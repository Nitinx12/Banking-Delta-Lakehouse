---
name: adding-new-source
description: Land a new table from a source system (MySQL, MongoDB, Databricks) into the raw layer.
trigger: adding a new source, landing a new table, new extractor
---

# Adding a New Source Table

This workflow covers landing a new table from a source system into the `raw` layer of the PostgreSQL warehouse.

## Procedure

1. **Update Extraction Logic**
   - Identify the source system: `extract_mysql.py`, `extract_mongo.py`, or `extract_databricks.py`.
   - Add the table/collection to the extractor's configuration or mapping.
   - Ensure the extractor handles watermarks correctly if incremental.

2. **Define Raw Table**
   - Create a migration file `V<n>__create_raw_<table_name>.sql` in the migrations folder.
   - The table must be in the `raw` schema.
   - Include required audit columns: `_batch_id` and `_loaded_at` (timestamptz).

3. **Update Orchestration**
   - If a new extractor script is needed, update `scripts/run_jobs.py` to include it.
   - Ensure the table is registered for extraction in the source configuration.

4. **Verify Landing**
   - Run the extraction for the specific source:
     `python scripts/run_jobs.py --sources <mysql|mongo|databricks>`
   - Verify data exists in `raw.<table_name>`.

## Example
Adding `customer_addresses` from MySQL:
- Update `extract_mysql.py` to include `customer_addresses`.
- Create `V123__create_raw_customer_addresses.sql` defining `raw.customer_addresses`.
- Run `python scripts/run_jobs.py --sources mysql`.

## Done Checklist
- [ ] Table created in `raw` schema with audit columns.
- [ ] Extractor updated and successfully lands data.
- [ ] Watermarks are advancing in `audit.extract_watermarks`.
- [ ] `make sql-lint` passes.
