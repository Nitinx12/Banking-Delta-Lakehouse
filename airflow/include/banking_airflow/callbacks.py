"""Airflow task callbacks. Alerting must never raise into the scheduler."""

from __future__ import annotations

import logging
import os
from typing import Any

log = logging.getLogger("banking.airflow.callbacks")

# Operator escape hatch: set ALERT_ON_TASK_FAILURE=false in a noisy environment.
_ALERT_ON_TASK_FAILURE = (
    os.environ.get("ALERT_ON_TASK_FAILURE", "true").lower() == "true"
)


def notify_task_failure(context: dict[str, Any]) -> None:
    """Send one task-failure mail on final failure. Never raise into Airflow."""
    if not _ALERT_ON_TASK_FAILURE:
        return
    try:
        from banking_airflow import notify

        notify.send_task_failure(context)
    except Exception:  # alerting must never raise into the scheduler
        log.exception("Task-failure notification failed; the task state is unaffected")
