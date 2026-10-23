"""Banking-Delta daily pipeline (extract -> gates -> staging -> analytics -> marts -> publish).

Orchestration only. All logic lives in main.py / scripts / src / sql.
Runbook: airflow/AIRFLOW_AGENT_GUIDE.md §14.
"""

from __future__ import annotations

import os
from datetime import timedelta

import pendulum
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import DAG, Param, task

from banking_airflow.callbacks import notify_task_failure
from banking_airflow.commands import (
    RUN_ENV,
    banking_cmd,
    extract_cmd,
    finalize_cmd,
    load_or_test_cmd,
    publish_cmd,
    report_command,
)

DAG_ID = "banking_delta_daily"
TZ = pendulum.timezone(os.environ.get("TIMEZONE", "Asia/Kolkata"))
EXTRACT_SPARK_DRIVER_MEMORY = os.environ.get("EXTRACT_SPARK_DRIVER_MEMORY", "1g")

default_args = {
    "owner": "data-platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=30),
    "execution_timeout": timedelta(hours=1),
    "on_failure_callback": notify_task_failure,
    "email_on_failure": False,
    "email_on_retry": False,
}


def step(
    task_id: str, args: str, env: dict[str, str] | None = None, **kwargs
) -> BashOperator:
    return BashOperator(
        task_id=task_id,
        bash_command=banking_cmd(args),
        env=env or RUN_ENV,
        append_env=True,
        **kwargs,
    )


with DAG(
    dag_id=DAG_ID,
    description="MySQL/Mongo/Databricks -> Spark -> PostgreSQL warehouse -> Databricks Delta marts",
    schedule=os.environ.get("BANKING_DAG_SCHEDULE", "0 2 * * *"),
    start_date=pendulum.datetime(2026, 1, 1, tz=TZ),
    catchup=False,
    max_active_runs=1,
    max_active_tasks=4,
    dagrun_timeout=timedelta(hours=5),
    default_args=default_args,
    params={
        "publish_full": Param(
            False,
            type="boolean",
            description="Republish ALL marts to Databricks (--full)",
        )
    },
    tags=["banking", "etl", "production"],
    doc_md=__doc__,
) as dag:
    preflight = step(
        "preflight",
        "-m banking_airflow.preflight",
        retries=3,
        retry_delay=timedelta(minutes=2),
        execution_timeout=timedelta(minutes=10),
    )

    extracts = [
        step(
            f"extract_{source}",
            extract_cmd(source),
            env={**RUN_ENV, "SPARK_DRIVER_MEMORY": EXTRACT_SPARK_DRIVER_MEMORY},
            pool="spark_jvm",
            priority_weight=weight,
            weight_rule="absolute",
            retries=2,
            retry_delay=timedelta(minutes=10),
            retry_exponential_backoff=True,
            max_retry_delay=timedelta(minutes=30),
            execution_timeout=timedelta(hours=2),
        )
        for source, weight in (("mongo", 30), ("databricks", 20), ("mysql", 10))
    ]

    gate_kw = dict(retries=0, execution_timeout=timedelta(minutes=30))
    load_kw = dict(retries=1, execution_timeout=timedelta(hours=1))

    raw_tests = step("raw_tests", load_or_test_cmd("raw-tests"), **gate_kw)
    staging_load = step("staging_load", load_or_test_cmd("staging-load"), **load_kw)
    staging_tests = step("staging_tests", load_or_test_cmd("staging-tests"), **gate_kw)
    analytics_load = step(
        "analytics_load", load_or_test_cmd("analytics-load"), **load_kw
    )
    analytics_tests = step(
        "analytics_tests", load_or_test_cmd("analytics-tests"), **gate_kw
    )
    marts_load = step("marts_load", load_or_test_cmd("marts-load"), **load_kw)
    marts_tests = step("marts_tests", load_or_test_cmd("marts-tests"), **gate_kw)
    publish = step(
        "publish",
        publish_cmd(),
        pool="spark_jvm",
        retries=2,
        retry_exponential_backoff=True,
        max_retry_delay=timedelta(minutes=30),
        execution_timeout=timedelta(hours=2),
    )

    finalize = step(
        "finalize_audit",
        finalize_cmd(),
        trigger_rule="all_done",
        retries=1,
        execution_timeout=timedelta(minutes=10),
    )

    build_report = step(
        "build_report",
        report_command("daily"),
        trigger_rule="all_done",
        retries=1,
        retry_delay=timedelta(minutes=2),
        execution_timeout=timedelta(minutes=15),
    )

    @task(
        task_id="send_pipeline_summary",
        trigger_rule="all_done",
        retries=3,
        retry_delay=timedelta(minutes=2),
        on_failure_callback=None,
        execution_timeout=timedelta(minutes=10),
    )
    def send_pipeline_summary(**context) -> None:
        from banking_airflow.summary import build_and_send

        build_and_send(context)

    @task(
        task_id="fail_if_any_failed",
        trigger_rule="one_failed",
        retries=0,
        on_failure_callback=None,
    )
    def fail_if_any_failed(**context) -> None:
        from banking_airflow.summary import (
            collect_task_states,
            failure_reasons,
        )

        dag_run = context.get("dag_run")
        dag_id = getattr(context.get("dag"), "dag_id", "banking_delta_daily")
        run_id = context.get("run_id") or getattr(dag_run, "run_id", "")
        task_states = collect_task_states(context, dag_id, run_id)

        failed = failure_reasons(task_states)
        detail = ", ".join(failed) if failed else "a pipeline step did not complete"
        raise RuntimeError(
            f"Pipeline failed ({detail}) - see summary email and task logs."
        )

    summary = send_pipeline_summary()
    gate = fail_if_any_failed()

    steps = [
        raw_tests,
        staging_load,
        staging_tests,
        analytics_load,
        analytics_tests,
        marts_load,
        marts_tests,
        publish,
    ]
    preflight >> extracts
    extracts >> raw_tests
    for upstream, downstream in zip(steps, steps[1:]):
        upstream >> downstream
    [preflight, *extracts, *steps] >> finalize >> build_report >> summary
    [preflight, *extracts, *steps] >> gate
