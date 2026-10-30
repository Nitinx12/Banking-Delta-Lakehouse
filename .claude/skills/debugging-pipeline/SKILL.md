---
name: debugging-pipeline
description: Use audit tables and logs to identify and fix pipeline failures.
trigger: debugging pipeline, finding failures, pipeline error, why did it fail
---

# Debugging the Pipeline

This workflow covers the process of identifying the root cause of a pipeline failure using the built-in audit system and logs.

## Procedure

1. **Identify the Failing Step**
   - Check the Airflow log or `main.py` output to see which of the 9 steps failed.
   - Example: `staging-tests` failed $\rightarrow$ look at DQ. `analytics-load` failed $\rightarrow$ look at SQL procedure.

2. **Query the Audit System**
   - **For DQ Failures**:
     - Query `audit.dq_run` to find the latest failed check.
     - Query `audit.dq_violation` using the `run_id` to see specific bad rows and error messages.
   - **For Load Failures**:
     - Check `audit.table_runs` to see which table was being processed when the failure occurred.
     - Check `audit.pipeline_runs` for overall status and timing.

3. **Inspect the Data**
   - Use the violation details from `audit.dq_violation` to find the offending rows in the layer's table.
   - Verify if the issue is a source data anomaly or a bug in the transformation logic.

4. **Trace Watermarks**
   - For incremental load issues, check `audit.extract_watermarks` or `audit.etl_watermarks` to see if the pipeline is missing data or reprocessing too much.

5. **Reproduce and Fix**
   - Use `python main.py --only <step>` to rerun only the failing part after applying a fix.

## Example
`main.py` fails at `raw-tests`:
- Query `SELECT * FROM audit.dq_run WHERE status = 'FAIL' ORDER BY created_at DESC LIMIT 1;`
- Get `run_id`, then `SELECT * FROM audit.dq_violation WHERE run_id = <id>;`
- Find that `raw.customers` has nulls in `customer_id`.
- Fix the source system or adjust the DQ threshold if it's an expected anomaly.

## Done Checklist
- [ ] Identified the failing step and root cause.
- [ ] Verified the fix by running the specific step via `main.py`.
- [ ] Confirmed that the audit tables reflect the successful run.
