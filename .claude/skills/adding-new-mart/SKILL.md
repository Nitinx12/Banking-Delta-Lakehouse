---
name: adding-new-mart
description: Create a new business table in the marts layer and publish it to Databricks Delta.
trigger: adding a new mart, creating a business table, publish mart
---

# Adding a New Mart

This workflow covers creating a new business mart in the `marts` layer and ensuring it is published to the Databricks Delta Lakehouse.

## Procedure

1. **Design the Mart**
   - Determine the source tables from the `analytics` (dim/fact) layer.
   - Define the business logic and required columns.

2. **Implement SQL Transformation**
   - Create a new procedure `etl.sp_load_mart_<name>` in `sql/marts/`.
   - Follow naming conventions: `marts.mart_<name>`.
   - Ensure the procedure uses `NUMERIC(18,2)` for money and `timestamptz` for times.
   - Implement the load as an idempotent operation.

3. **Register in Master Load**
   - Add the `CALL etl.sp_load_mart_<name>(...)` to `sql/marts/00_master_load.sql`.

4. **Configure Publishing**
   - Update `src/jobs/publish_marts.py` (or its config) to include the new mart for publishing to Databricks.
   - Verify the publishing logic handles the watermark for the new table.

5. **Verify End-to-End**
   - Run the marts load: `python main.py --only marts-load`.
   - Run the publish job: `python main.py --only publish`.
   - Verify data in Databricks `marts.mart_<name>`.

## Example
Creating `mart_monthly_revenue`:
- Create `sql/marts/sp_load_mart_monthly_revenue.sql`.
- Add `CALL etl.sp_load_mart_monthly_revenue(...)` to `sql/marts/00_master_load.sql`.
- Add `mart_monthly_revenue` to the publish list in `publish_marts.py`.

## Done Checklist
- [ ] Mart table created in `marts` schema.
- [ ] Transformation procedure implemented and registered in `00_master_load.sql`.
- [ ] Mart successfully published to Databricks Delta.
- [ ] `make sql-lint` passes.
