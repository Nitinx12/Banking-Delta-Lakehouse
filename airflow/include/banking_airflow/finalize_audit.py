"""Close this DAG run's audit.pipeline_runs row, once, after every task ended.

Runs as the finalize_audit task with trigger_rule=all_done, so the audit row is
closed whether the pipeline passed or failed; summary reads it afterwards.
"""

from __future__ import annotations

import os

from utils.audit import finalize_dag_run
from utils.logger import get_logger

log = get_logger(__name__)


def main() -> int:
    dag_id = os.environ.get("AIRFLOW_CTX_DAG_ID")
    dag_run_id = os.environ.get("AIRFLOW_CTX_DAG_RUN_ID")
    if not dag_id or not dag_run_id:
        log.info("No Airflow run context - nothing to finalize")
        return 0
    status = finalize_dag_run(dag_id, dag_run_id)
    if status is None:
        log.info("No pipeline run recorded for %s/%s", dag_id, dag_run_id)
    else:
        log.info("Pipeline run for %s/%s closed: %s", dag_id, dag_run_id, status)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
