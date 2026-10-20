"""Read-only view of the pipeline's audit schema (audit.*).

The summary task may not touch the Airflow metadata DB, so it reads the same
tables the extract runner and publisher already write. Connection settings come
from the repo's existing PG_* variables. Every query is read-only and scoped to
one (dag_id, dag_run_id); only counts, names, statuses and timestamps are read.
"""

from __future__ import annotations

import logging
import os
from typing import Any

log = logging.getLogger("banking.airflow.audit_reader")

# Columns are limited to counts, names, statuses and timestamps - never row data.
TABLES_SQL = """
SELECT tr.airflow_task_id,
       tr.processing_layer,
       tr.source_table,
       tr.target_table,
       tr.status,
       tr.attempt_number,
       tr.rows_extracted,
       tr.rows_landed,
       tr.watermark_start,
       tr.watermark_end,
       tr.duration_seconds
FROM audit.table_runs tr
JOIN audit.pipeline_runs pr ON pr.pipeline_run_id = tr.pipeline_run_id
WHERE pr.dag_id = %(dag_id)s AND pr.dag_run_id = %(dag_run_id)s
ORDER BY tr.processing_layer, tr.source_table, tr.attempt_number
"""

RUN_SQL = """
SELECT pipeline_run_id, status, run_type, trigger_type,
       total_tables, successful_tables, failed_tables, skipped_tables,
       started_at, ended_at, duration_seconds
FROM audit.pipeline_runs
WHERE dag_id = %(dag_id)s AND dag_run_id = %(dag_run_id)s
"""

ERRORS_SQL = """
SELECT e.source_table, e.target_table, e.processing_layer,
       e.error_category, e.severity, e.retry_attempt, e.is_recoverable,
       e.resolution_status
FROM audit.pipeline_errors e
JOIN audit.pipeline_runs pr ON pr.pipeline_run_id = e.pipeline_run_id
WHERE pr.dag_id = %(dag_id)s AND pr.dag_run_id = %(dag_run_id)s
ORDER BY e.error_timestamp
"""

DQ_SQL = """
SELECT d.check_name, d.status, d.records_checked, d.records_failed
FROM audit.data_quality_results d
JOIN audit.pipeline_runs pr ON pr.pipeline_run_id = d.pipeline_run_id
WHERE pr.dag_id = %(dag_id)s AND pr.dag_run_id = %(dag_run_id)s
ORDER BY d.status, d.check_name
"""

LATEST_DQ_SQL = """
SELECT layer, script_name, status, violation_count
FROM audit.v_dq_latest
ORDER BY layer, script_name
"""


def _connect():
    """Read-only, autocommit connection to the warehouse (caller closes it)."""
    import psycopg2

    conn = psycopg2.connect(
        host=os.environ.get("PG_HOST"),
        port=int(os.environ.get("PG_PORT", "5432")),
        dbname=os.environ.get("PG_DB"),
        user=os.environ.get("PG_USER"),
        password=os.environ.get("PG_PASS", ""),
        connect_timeout=10,
        application_name="banking-airflow-summary",
    )
    conn.set_session(readonly=True, autocommit=True)
    return conn


def _query(sql: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    from psycopg2.extras import RealDictCursor

    conn = _connect()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(sql, params or {})
            return [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()


def table_runs(dag_id: str, dag_run_id: str) -> list[dict[str, Any]]:
    """One row per table attempt for this DAG run (counts, watermarks, status)."""
    return _query(TABLES_SQL, {"dag_id": dag_id, "dag_run_id": dag_run_id})


def pipeline_run(dag_id: str, dag_run_id: str) -> dict[str, Any] | None:
    """The shared pipeline_runs row for this DAG run, or None if never started."""
    rows = _query(RUN_SQL, {"dag_id": dag_id, "dag_run_id": dag_run_id})
    return rows[0] if rows else None


def errors(dag_id: str, dag_run_id: str) -> list[dict[str, Any]]:
    """Errors logged against this DAG run's pipeline row."""
    return _query(ERRORS_SQL, {"dag_id": dag_id, "dag_run_id": dag_run_id})


def dq_results(dag_id: str, dag_run_id: str) -> list[dict[str, Any]]:
    """Data-quality results attached to this DAG run."""
    return _query(DQ_SQL, {"dag_id": dag_id, "dag_run_id": dag_run_id})


def latest_dq() -> list[dict[str, Any]]:
    """Latest result per DQ script (audit.v_dq_latest), independent of the run."""
    return _query(LATEST_DQ_SQL)
