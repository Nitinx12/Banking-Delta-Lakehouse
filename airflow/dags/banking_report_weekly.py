"""Weekly Banking-Delta digest report (Monday 08:00 IST).

Builds the weekly PDF and attaches it to the summary mail.
Runbook: airflow/AIRFLOW_AGENT_GUIDE.md §13.
"""

from __future__ import annotations

import os
from datetime import timedelta

import pendulum
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import DAG, task
from banking_airflow.commands import RUN_ENV, banking_cmd, report_command

DAG_ID = "banking_report_weekly"
TZ = pendulum.timezone(os.environ.get("TIMEZONE", "Asia/Kolkata"))

default_args = {
    "owner": "data-platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
    "execution_timeout": timedelta(minutes=30),
    "email_on_failure": False,
    "email_on_retry": False,
}

with DAG(
    dag_id=DAG_ID,
    description="Weekly Banking-Delta digest report (Monday 08:00 IST)",
    schedule="0 8 * * 1",
    start_date=pendulum.datetime(2026, 1, 1, tz=TZ),
    catchup=False,
    max_active_runs=1,
    default_args=default_args,
    tags=["banking", "report", "weekly"],
    doc_md=__doc__,
) as dag:
    build_weekly_report = BashOperator(
        task_id="build_weekly_report",
        bash_command=banking_cmd(report_command("weekly")),
        env=RUN_ENV,
        append_env=True,
        retries=1,
        retry_delay=timedelta(minutes=2),
        execution_timeout=timedelta(minutes=15),
    )

    @task(
        task_id="send_weekly_summary",
        trigger_rule="all_done",
        retries=3,
        retry_delay=timedelta(minutes=2),
        on_failure_callback=None,
        execution_timeout=timedelta(minutes=10),
    )
    def send_weekly_summary(**context) -> None:
        from banking_airflow.summary import build_and_send

        build_and_send(context)

    build_weekly_report >> send_weekly_summary()
