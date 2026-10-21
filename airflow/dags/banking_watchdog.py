"""Banking-Delta watchdog - alerts when the daily pipeline stops succeeding.

Covers what Airflow cannot report about itself (scheduler down, DAG paused, run
stuck, mail broken). Runbook: airflow/AIRFLOW_AGENT_GUIDE.md §12.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

import pendulum
from airflow.sdk import DAG

from banking_airflow.commands import RUN_ENV, banking_cmd, report_command

TZ = pendulum.timezone(os.environ.get("TIMEZONE", "Asia/Kolkata"))
PIPELINE_DAG_ID = "banking_delta_daily"
MAX_AGE_HOURS = int(os.environ.get("WATCHDOG_MAX_AGE_HOURS", "30"))
STUCK_HOURS = int(os.environ.get("WATCHDOG_STUCK_HOURS", "5"))


def _connect():
    import psycopg2

    return psycopg2.connect(
        host=os.environ.get("PG_HOST"),
        port=int(os.environ.get("PG_PORT", "5432")),
        dbname=os.environ.get("PG_DB"),
        user=os.environ.get("PG_USER"),
        password=os.environ.get("PG_PASS", ""),
        connect_timeout=10,
        application_name="banking-watchdog",
    )


def _latest(conn, query: str):
    with conn.cursor() as cur:
        cur.execute(query, {"dag_id": PIPELINE_DAG_ID})
        return cur.fetchone()


def _build_incident_report(dag_run_id: str) -> None:
    """Trigger the incident report for a specific DAG run."""
    import subprocess

    cmd = (
        banking_cmd(report_command("incident"))
        .replace("{{ dag.dag_id }}", PIPELINE_DAG_ID)
        .replace("'{{ run_id }}'", f"'{dag_run_id}'")
    )
    result = subprocess.run(
        cmd,
        shell=True,
        env={**os.environ, **RUN_ENV},
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        import logging

        logging.getLogger("banking.watchdog").warning(
            "Incident report build failed for %s: %s", dag_run_id, result.stderr
        )


def check_pipeline_health() -> None:
    """Send [MISSED]/[STUCK]/[WATCHDOG-ERROR]; stay silent when healthy."""
    from banking_airflow import notify

    try:
        conn = _connect()
    except Exception as exc:  # noqa: BLE001 - cannot even reach the warehouse
        notify.send_email(
            f"[WATCHDOG-ERROR] cannot reach the warehouse ({type(exc).__name__})",
            "<p>The watchdog could not connect to the warehouse; it cannot tell whether the "
            "pipeline ran.</p>",
            "Watchdog could not connect to the warehouse; pipeline status unknown.",
        )
        return

    try:
        success = _latest(
            conn,
            """SELECT status, ended_at FROM audit.pipeline_runs
               WHERE dag_id = %(dag_id)s AND status = 'SUCCESS'
               ORDER BY ended_at DESC NULLS LAST LIMIT 1""",
        )
        running = _latest(
            conn,
            """SELECT status, started_at, dag_run_id FROM audit.pipeline_runs
               WHERE dag_id = %(dag_id)s AND status IN ('RUNNING', 'PARTIAL')
               ORDER BY started_at DESC LIMIT 1""",
        )
    finally:
        conn.close()

    now = datetime.now(timezone.utc)
    if success and success[1] is not None:
        age = now - success[1]
        if age > timedelta(hours=MAX_AGE_HOURS):
            hours = int(age.total_seconds() // 3600)
            notify.send_email(
                f"[MISSED] Banking-Delta pipeline has not succeeded in {hours} h",
                f"<p>The last successful run of <code>{PIPELINE_DAG_ID}</code> finished "
                f"{hours} h ago (threshold {MAX_AGE_HOURS} h).</p>",
                f"Last success {hours} h ago (threshold {MAX_AGE_HOURS} h).",
            )
            # Build incident report for the latest run
            latest_run = _latest(
                _connect(),
                """SELECT dag_run_id FROM audit.pipeline_runs
                   WHERE dag_id = %(dag_id)s ORDER BY started_at DESC LIMIT 1""",
            )
            if latest_run:
                _build_incident_report(latest_run[0])
            return

    if running and running[1] is not None:
        stuck = now - running[1]
        if stuck > timedelta(hours=STUCK_HOURS):
            hours = int(stuck.total_seconds() // 3600)
            dag_run_id = running[2] if len(running) > 2 else None
            notify.send_email(
                f"[STUCK] Banking-Delta pipeline has been {running[0]} for {hours} h",
                f"<p>Run of <code>{PIPELINE_DAG_ID}</code> has been <strong>{running[0]}</strong> "
                f"for {hours} h (threshold {STUCK_HOURS} h).</p>",
                f"Run {running[0]} for {hours} h (threshold {STUCK_HOURS} h).",
            )
            if dag_run_id:
                _build_incident_report(dag_run_id)


with DAG(
    dag_id="banking_watchdog",
    description="Alert if banking_delta_daily has not succeeded recently",
    schedule="0 */3 * * *",
    start_date=pendulum.datetime(2026, 1, 1, tz=TZ),
    catchup=False,
    max_active_runs=1,
    default_args={
        "owner": "data-platform",
        "retries": 2,
        "retry_delay": timedelta(minutes=5),
    },
    tags=["banking", "monitoring"],
    doc_md=__doc__,
) as dag:
    from airflow.providers.standard.operators.python import PythonOperator

    PythonOperator(
        task_id="check_pipeline_health", python_callable=check_pipeline_health
    )
