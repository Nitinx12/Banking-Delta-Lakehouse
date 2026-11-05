---
name: debugging-pipeline
description: Use audit tables and logs to identify and fix pipeline failures.
trigger: debugging pipeline, finding failures, pipeline error, why did it fail, dq failed
---

# Debugging the Pipeline

Root-cause a pipeline failure using the audit system, the DQ runners and logs.

## Procedure

1. **Identify the failing step**
   - Airflow log for the DAG run, or the `main.py` / `make daily` output.
   - `python main.py --list` shows the 10 steps in order: `preflight`,
     `raw-inject`, `raw-tests`, `staging-load`, `staging-tests`, `analytics-load`,
     `analytics-tests`, `marts-load`, `marts-tests`, `publish`.
   - `preflight` failed → a source did not answer; read the summary `Detail` and the
     `banking.utils.preflight` log lines (auth errors are not retried, budgets are
     `PREFLIGHT_*`). It runs in-process, so it writes no `audit.*` row.
   - `*-tests` failed → data problem (§2 below). `*-load` failed → SQL procedure
     problem (§3 below). `publish` failed → Databricks/connector problem.

2. **DQ failures**
   - `SELECT run_id, script_name, status, violation_count, finished_at
     FROM audit.dq_run WHERE status = 'FAIL' ORDER BY finished_at DESC LIMIT 5;`
   - `SELECT message FROM audit.dq_violation WHERE run_id = '<id>';` — each row is
     one human-readable violation (`schema.table: ...`).
   - Re-run just the failing suite with detail:
     `python scripts/run_<layer>_tests.py --only 02 --verbose`, or `make dq-<layer>`.

3. **Load failures**
   - `SELECT source_table, target_table, status, started_at, ended_at, error_id
     FROM audit.table_runs WHERE status = 'FAILED' ORDER BY started_at DESC;`
   - `SELECT * FROM audit.pipeline_runs WHERE status <> 'SUCCESS'
     ORDER BY started_at DESC LIMIT 5;` (also holds run durations).
   - `audit.pipeline_errors` keeps the error text for `error_id`.

4. **Inspect the data**
   - Pull offending rows with the violation message (e.g. null/duplicate keys),
     then decide: source anomaly, transformation bug, or genuinely missing
     expectation. Fix the cause — **never relax a DQ check just to go green**.

5. **Trace watermarks (incremental tables)**
   - `SELECT * FROM audit.etl_watermarks;` (ETL) and `audit.extract_watermarks`
     (extract). Missing data → watermark too high or a failed transaction that
     committed early; duplicate reprocessing → watermark stuck or not seeded
     (`scripts/seed_watermarks.py`).

6. **Reproduce and verify**
   - Re-run only the failing step: `python main.py --only <step>` or the matching
     `make` target (`make staging`, `make dq-staging`, ...).
   - Confirm the audit rows now show `SUCCESS`/`PASS`.

## Example

`make daily` stops at `raw-tests` (i.e. `raw-tests` step failed):

```sql
SELECT run_id, script_name, violation_count FROM audit.dq_run
WHERE status = 'FAIL' ORDER BY finished_at DESC LIMIT 1;
SELECT message FROM audit.dq_violation WHERE run_id = '<id>';
-- e.g. raw.customers: 3 rows with NULL customer_id
```

Then fix the source/extract, re-run `make dq-raw`, continue with `make daily`.

## Done Checklist

- [ ] Failing step and root cause identified from `audit.*`.
- [ ] Fix applied at the cause, not by weakening a check.
- [ ] Re-run of that step passes; audit tables reflect `SUCCESS`/`PASS`.
