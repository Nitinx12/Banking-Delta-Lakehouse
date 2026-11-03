---
name: operate-the-pipeline
description: Run the full daily pipeline (extract -> staging -> analytics -> marts -> publish) with its DQ gates, and verify the run.
trigger: run pipeline, make daily, full run, execute main.py, run all layers, daily job
---

# Operating the Pipeline

One end-to-end run of the project, with the gates that protect each layer.

## Preconditions

- `.env` configured (PostgreSQL + sources + Databricks); `make install` done.
- Warehouse bootstrapped: `sql/scripts/` applied in numeric order via `psql`
  (schemas, audit tables, source registry, DQ procedures) — see each file's
  header. `sql-smoke`/`integration` are for **disposable** DBs only
  (`ALLOW_SQL_SMOKE=1`).
- New incremental tables seeded: `python scripts/seed_watermarks.py --dry-run`
  then without `--dry-run`.
- No source systems? Use `make load-raw-csv` instead of the extract (see
  `bootstrap-from-csv`), then start at the staging step.

## Two equivalent ways to run

```bash
make daily          # shell orchestrator: every step in order, stops on first failure
python main.py      # same 9 steps with audit correlation and rich output
python main.py --list                  # show steps
python main.py --only staging-load     # run a single step
python main.py --only raw-tests        # re-run one gate
```

The 9 steps, in order — each `*-tests` gate must pass before its layer proceeds:

| # | Step | What it does |
| --- | --- | --- |
| 1 | `raw-inject` | extracts MySQL/MongoDB/Databricks → `raw.*` (`make run-jobs`) |
| 2 | `raw-tests` | DQ gate (`make dq-raw`) |
| 3 | `staging-load` | `CALL staging.sp_load_all()` (`make staging`) |
| 4 | `staging-tests` | DQ gate (`make dq-staging`) |
| 5 | `analytics-load` | `CALL analytics.sp_load_all()` (`make analytics`) |
| 6 | `analytics-tests` | DQ gate (`make dq-analytics`) |
| 7 | `marts-load` | `CALL marts.sp_load_all()` (`make marts`) |
| 8 | `marts-tests` | DQ gate (`make dq-marts`) |
| 9 | `publish` | marts → Databricks Delta (`make publish`) |

Rules that hold during any run:

- A critical DQ failure **blocks** everything downstream, including publish.
- Loads are idempotent — re-running a step with the same input is safe.
- Watermarks advance only inside the load transaction (never manually).
- Only the owners in `ARCHITECTURE.md` write to each schema.

## Airflow (scheduled runs)

```bash
make up        # docker compose: airflow-init then up (GIT_SHA stamped)
make down
```

UI: http://127.0.0.1:8080 — DAGs are created **paused**; un-pause
`banking_delta_daily` / `banking_report_weekly` deliberately. Airflow drives the
same steps (`main.py`) and writes `audit.pipeline_runs` /
`audit.table_runs` (`airflow/include/banking_airflow/`).

## Verifying a run

```sql
SELECT dag_id, run_type, status, total_tables, successful_tables,
       to_char(duration_seconds * interval '1 second', 'MI:SS') AS dur
FROM audit.pipeline_runs ORDER BY started_at DESC LIMIT 5;

SELECT source_table, status, rows_landed, ended_at
FROM audit.table_runs ORDER BY started_at DESC LIMIT 20;

SELECT layer, script_name, status, violation_count, finished_at
FROM audit.dq_run ORDER BY finished_at DESC LIMIT 10;
```

Quick health: `SELECT count(*) FROM marts.mart_customer_360;` and, after publish,
the table in the Databricks `marts` schema.

## When something fails

Use the `debugging-pipeline` skill: `audit.dq_run`/`audit.dq_violation` for gate
failures, `audit.table_runs`/`audit.pipeline_errors` for load failures,
`audit.etl_watermarks`/`audit.extract_watermarks` for incremental problems.
Fix the cause; never weaken a check to get a green run.

## Done Checklist

- [ ] All 9 steps `SUCCESS` in `audit.pipeline_runs`.
- [ ] Every `audit.dq_run` since the run shows `PASS`.
- [ ] Row counts in marts look sane; publish landed (if credentials present).
- [ ] No `.env`/secrets were logged or committed.
