"""DAG integrity: the graph, retries and run-state honesty rules from §9/§15."""

from __future__ import annotations

import os
from datetime import timedelta

import pytest

from conftest import DAGS_DIR

pytestmark = pytest.mark.smoke

MAIN_STEPS = [
    "raw-tests",
    "staging-load",
    "staging-tests",
    "analytics-load",
    "analytics-tests",
    "marts-load",
    "marts-tests",
    "publish",
]
STEP_TASKS = [s.replace("-", "_") for s in MAIN_STEPS]
DQ_GATES = {"raw_tests", "staging_tests", "analytics_tests", "marts_tests"}
SPARK_TASKS = {"extract_mongo", "extract_databricks", "extract_mysql", "publish"}


def _dagbag():
    from airflow.dag_processing.dagbag import DagBag

    return DagBag(dag_folder=str(DAGS_DIR))


@pytest.fixture(scope="module")
def dagbag():
    bag = _dagbag()
    assert not bag.import_errors, f"DAG import errors: {bag.import_errors}"
    return bag


@pytest.fixture(scope="module")
def daily(dagbag):
    assert "banking_delta_daily" in dagbag.dags
    return dagbag.dags["banking_delta_daily"]


def test_both_dags_load(dagbag):
    assert {"banking_delta_daily", "banking_watchdog"} <= set(dagbag.dags)


def test_daily_dag_settings(daily):
    assert daily.catchup is False
    assert daily.max_active_runs == 1
    assert daily.dagrun_timeout == timedelta(hours=5)
    assert daily.dagrun_timeout < timedelta(hours=6)


def test_every_pipeline_step_has_a_task(daily):
    ids = set(daily.task_ids)
    for task_id in STEP_TASKS:
        assert task_id in ids, f"missing task for main.py step: {task_id}"
    assert "preflight" in ids
    assert {"send_pipeline_summary", "fail_if_any_failed"} <= ids


def test_linear_order_matches_main(daily):
    chain = STEP_TASKS
    for upstream, downstream in zip(chain, chain[1:]):
        assert downstream in daily.get_task(upstream).downstream_task_ids


def test_gates_run_first(daily):
    for extract in ("extract_mongo", "extract_databricks", "extract_mysql"):
        assert "raw_tests" in daily.get_task(extract).downstream_task_ids


def test_dq_gates_never_retry(daily):
    for task_id in DQ_GATES:
        assert daily.get_task(task_id).retries == 0


def test_spark_tasks_share_the_spark_pool(daily):
    for task_id in SPARK_TASKS:
        assert daily.get_task(task_id).pool == "spark_jvm"


def test_summary_always_runs(daily):
    assert daily.get_task("send_pipeline_summary").trigger_rule == "all_done"


def test_finalize_audit_closes_the_run_before_summary(daily):
    finalize = daily.get_task("finalize_audit")
    assert finalize.trigger_rule == "all_done"
    expected = {
        "preflight",
        "extract_mongo",
        "extract_databricks",
        "extract_mysql",
        *STEP_TASKS,
    }
    assert finalize.upstream_task_ids == expected
    assert finalize.execution_timeout < timedelta(hours=6)
    summary_upstream = daily.get_task("send_pipeline_summary").upstream_task_ids
    assert summary_upstream == {"finalize_audit"}
    assert "publish" not in summary_upstream


def test_extract_tasks_size_their_own_driver_memory(daily):
    want = os.environ.get("EXTRACT_SPARK_DRIVER_MEMORY", "1g")
    for task_id in ("extract_mongo", "extract_databricks", "extract_mysql"):
        assert daily.get_task(task_id).env.get("SPARK_DRIVER_MEMORY") == want


def test_fail_if_any_failed_makes_the_run_fail(daily):
    gate = daily.get_task("fail_if_any_failed")
    assert gate.trigger_rule == "one_failed"
    upstream = gate.upstream_task_ids
    for task_id in ["preflight", *STEP_TASKS]:
        assert task_id in upstream, f"{task_id} must gate the run state"


def test_no_email_on_failure_or_retry(daily):
    for task in daily.tasks:
        assert getattr(task, "email_on_failure", False) is False
        assert getattr(task, "email_on_retry", False) is False


def test_every_task_has_a_timeout(daily):
    for task in daily.tasks:
        assert task.execution_timeout is not None, (
            f"{task.task_id} has no execution_timeout"
        )


def test_no_single_task_timeout_reaches_the_reaper(daily):
    # The reaper fails RUNNING audit.table_runs rows older than 6 h at every job
    # start, so no single task may be allowed to sit that long (guide §9.2).
    reaper = timedelta(hours=6)
    for task in daily.tasks:
        if task.task_id in {"fail_if_any_failed"}:
            continue
        assert task.execution_timeout < reaper, (
            f"{task.task_id} timeout {task.execution_timeout} reaches the 6 h reaper"
        )


def test_dagrun_timeout_is_below_the_reaper(daily):
    assert daily.dagrun_timeout < timedelta(hours=6)
