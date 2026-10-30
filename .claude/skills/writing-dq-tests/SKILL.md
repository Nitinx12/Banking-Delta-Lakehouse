---
name: writing-dq-tests
description: Add a new data quality check to a layer's DQ suite.
trigger: adding a DQ test, writing a data quality check, DQ suite
---

# Writing DQ Tests

This workflow covers adding a new data quality check to one of the four gated layers (`raw`, `staging`, `analytics`, `marts`).

## Procedure

1. **Identify the Layer**
   - Determine which layer the check belongs to: `tests/data-quality/<layer>/`.

2. **Create the Check File**
   - Create a file `NN_<check_name>.sql` using the next free number in the directory.
   - Implement the procedure `audit.dq_<layer>_<check_name>()`.
   - **Contract Requirements**:
     - Insert into `audit.dq_run`.
     - Insert violations into `audit.dq_violation`.
     - Update `audit.dq_run` with final status (`PASS`/`FAIL`) and count.
     - **COMMIT** the audit rows before **RAISING** an exception on failure.

3. **Register the Check**
   - Add the `CALL audit.dq_<layer>_<check_name>();` to `tests/data-quality/<layer>/00_master_<layer>_tests.sql`.

4. **Validate the Check**
   - Run the check specifically: `python scripts/run_<layer>_tests.py --only NN`.
   - **Prove it can fail**: Insert a bad row into a disposable DB, verify the check fails (exit code != 0), then clean up.

## Example
Adding a "no negative balance" check to staging:
- Create `tests/data-quality/staging/11_no_negative_balance.sql`.
- Define `audit.dq_staging_no_negative_balance()`.
- Add call to `tests/data-quality/staging/00_master_staging_tests.sql`.
- Run `python scripts/run_staging_tests.py --only 11`.

## Done Checklist
- [ ] Procedure follows the "COMMIT-before-RAISE" contract.
- [ ] Registered in the layer's `00_master_tests.sql`.
- [ ] `make sql-lint` passes.
- [ ] Verified that the check actually fails on bad data.
