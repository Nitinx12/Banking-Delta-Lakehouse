# Rule engine R001-R017: turns collected context sections into events and a verdict.
from __future__ import annotations

import statistics
from typing import Any, Callable

from .render import fmt_dur

LABELS = {
    "INFO": "HEALTHY",
    "MINOR": "ATTENTION",
    "MAJOR": "ACTION REQUIRED",
    "CRITICAL": "INCIDENT",
    "UNKNOWN": "UNKNOWN",
}
_RANK = {"INFO": 0, "MINOR": 1, "MAJOR": 2, "CRITICAL": 3, "UNKNOWN": -1}


def _event(
    rule: str,
    severity: str,
    layer: str | None,
    subject: str,
    category: str,
    first_seen: str,
    message: str,
    impact: str,
    runbook: str | None = "RUNBOOK.md#a-run-failed-triage",
) -> dict[str, Any]:
    layer_part = layer or "pipeline"
    return {
        "event_id": f"{rule}:{layer_part}:{subject}",
        "rule": rule,
        "severity": severity,
        "layer": layer,
        "subject": subject,
        "category": category,
        "first_seen": first_seen,
        "message": message,
        "impact": impact,
        "runbook": runbook,
    }


def _ended(context: dict[str, Any]) -> str:
    return str((context.get("run") or {}).get("ended_at") or "")


def r001_failed_run(context: dict[str, Any]) -> list[dict[str, Any]]:
    run = context.get("run") or {}
    if run.get("status") != "FAILED":
        return []
    return [
        _event(
            "R001",
            "CRITICAL",
            None,
            str(context["meta"]["dag_id"]),
            "UNKNOWN",
            _ended(context),
            f"run status FAILED, {run.get('failed_tables')} of "
            f"{run.get('total_tables')} tables failed",
            "nothing was published, yesterday's marts stand",
        )
    ]


def r002_partial_run(context: dict[str, Any]) -> list[dict[str, Any]]:
    run = context.get("run") or {}
    if run.get("status") != "PARTIAL":
        return []
    return [
        _event(
            "R002",
            "MAJOR",
            None,
            str(context["meta"]["dag_id"]),
            "DATA",
            _ended(context),
            f"run status PARTIAL, {run.get('failed_tables')} of "
            f"{run.get('total_tables')} tables failed",
            "some layers did not load; check the failed tables",
        )
    ]


def r003_dq_suite_fail(context: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        _event(
            "R003",
            "MAJOR",
            str(row["layer"]),
            f"audit.dq_{row['script_name'].removesuffix('.sql')}",
            "DATA",
            str(row.get("checked_at") or _ended(context)),
            f"violation_count={row.get('violation_count')}",
            f"{row['layer']} gate blocked everything downstream",
        )
        for row in context.get("dq", [])
        if row.get("status") == "FAIL"
    ]


def r004_publish_not_success(context: dict[str, Any]) -> list[dict[str, Any]]:
    events = []
    for row in context.get("tables", []):
        if row["layer"] != "publish":
            continue
        if row.get("status") != "SUCCESS":
            events.append(
                _event(
                    "R004",
                    "MAJOR",
                    "publish",
                    f"publish.{row['table']}",
                    "DATA",
                    _ended(context),
                    f"publish status {row.get('status')}",
                    "Databricks marts were not updated",
                )
            )
            continue
        extracted = row.get("rows_extracted")
        landed = row.get("rows_landed")
        if extracted is None or landed is None or int(extracted) == int(landed):
            continue
        events.append(
            _event(
                "R004",
                "MAJOR",
                "publish",
                f"publish.{row['table']}",
                "DATA",
                _ended(context),
                f"published {int(landed)} rows from {int(extracted)} source rows",
                "the published rows do not match the source rows",
            )
        )
    return events


def r005_final_attempt_error(context: dict[str, Any]) -> list[dict[str, Any]]:
    if (context.get("run") or {}).get("status") not in {"PARTIAL", "FAILED"}:
        return []
    return [
        _event(
            "R005",
            "MAJOR",
            str(error.get("layer")) if error.get("layer") else None,
            str(error.get("table") or context["meta"]["dag_id"]),
            str(error["category"]),
            str(error.get("timestamp") or _ended(context)),
            f"{error['category']} error on the final attempt",
            "the run did not recover",
        )
        for error in context.get("errors", [])
        if error.get("category") in {"CONNECTION", "SPARK"}
    ]


def r006_concurrency_resolved(context: dict[str, Any]) -> list[dict[str, Any]]:
    if (context.get("run") or {}).get("status") not in {"SUCCESS", "PARTIAL"}:
        return []
    return [
        _event(
            "R006",
            "MINOR",
            str(error.get("layer")) if error.get("layer") else None,
            str(error.get("table") or context["meta"]["dag_id"]),
            "CONCURRENCY",
            str(error.get("timestamp") or _ended(context)),
            "CONCURRENCY error resolved by a retry",
            "no impact, the retry won the lock",
        )
        for error in context.get("errors", [])
        if error.get("category") == "CONCURRENCY"
    ]


def r007_retried_tables(context: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        _event(
            "R007",
            "MINOR",
            str(table["layer"]),
            f"{table['layer']}.{table['table']}",
            "UNKNOWN",
            _ended(context),
            f"attempt_number={table['attempts']}",
            "a table needed more than one attempt",
        )
        for table in context.get("tables", [])
        if (table.get("attempts") or 1) > 1
    ]


def r008_dq_warning(context: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        _event(
            "R008",
            "MINOR",
            str(row["layer"]),
            f"audit.dq_{row['script_name'].removesuffix('.sql')}",
            "DATA",
            str(row.get("checked_at") or _ended(context)),
            f"WARNING check not passing, violation_count={row.get('violation_count')}",
            "warning only, nothing was blocked",
            runbook=None,
        )
        for row in context.get("dq", [])
        if row.get("status") == "WARNING"
    ]


def r009_volume_deviation(
    context: dict[str, Any], ratio: float = 0.5
) -> list[dict[str, Any]]:
    trends = [t for t in context.get("trends", []) if t.get("rows_landed") is not None]
    if len(trends) < 3:
        return []
    current = int(trends[-1]["rows_landed"])
    history = [int(t["rows_landed"]) for t in trends[:-1]]
    median = statistics.median(history)
    if not median:
        return []
    deviation = abs(current - median) / median
    if deviation <= ratio:
        return []
    return [
        _event(
            "R009",
            "MINOR",
            None,
            str(context["meta"]["dag_id"]),
            "VOLUME",
            _ended(context),
            f"rows_landed={current}, trailing median {int(median)}, "
            f"deviation {round(100 * deviation)} percent",
            "quiet or unusually loud night, check the source",
        )
    ]


def r010_zero_row_full_load(context: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        _event(
            "R010",
            "MAJOR",
            str(table["layer"]),
            f"{table['layer']}.{table['table']}",
            "DATA",
            _ended(context),
            "full load landed zero rows",
            "a full load table should always land rows",
        )
        for table in context.get("tables", [])
        if table["layer"] == "raw"
        and table.get("status") == "SUCCESS"
        and table.get("rows_landed") == 0
    ]


def r011_duration_regression(
    context: dict[str, Any], ratio: float = 1.5
) -> list[dict[str, Any]]:
    trends = [t for t in context.get("trends", []) if t.get("duration_s") is not None]
    if len(trends) < 3:
        return []
    current = float(trends[-1]["duration_s"])
    history = [float(t["duration_s"]) for t in trends[:-1]]
    median = statistics.median(history)
    if not median or current / median <= ratio:
        return []
    return [
        _event(
            "R011",
            "MINOR",
            None,
            str(context["meta"]["dag_id"]),
            "DURATION",
            _ended(context),
            f"duration_s={int(current)}, trailing median {fmt_dur(median)}, "
            f"ratio {current / median:.2f}",
            "later than usual, no data was lost",
        )
    ]


def r012_freshness_breach(context: dict[str, Any]) -> list[dict[str, Any]]:
    events = []
    for row in context.get("freshness", []):
        if not row.get("breached"):
            continue
        severity = "MAJOR" if row.get("severity") == "ERROR" else "MINOR"
        events.append(
            _event(
                "R012",
                severity,
                "raw",
                f"raw.{row['table']}",
                "FRESHNESS",
                _ended(context),
                f"age {int(row['age_s'])}s exceeds window {row['window']}",
                "landing data is older than its contract window",
            )
        )
    return events


def r013_schema_drift(context: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        _event(
            "R013",
            "MAJOR",
            str(row["layer"]),
            f"audit.dq_{row['script_name'].removesuffix('.sql')}",
            "DATA",
            str(row.get("checked_at") or _ended(context)),
            f"schema contract violation, violation_count={row.get('violation_count')}",
            "the landed schema drifted from the contract",
        )
        for row in context.get("dq", [])
        if row.get("status") == "FAIL" and "schema" in str(row["script_name"])
    ]


def r014_watchdog_alert(alerts: list[str]) -> list[dict[str, Any]]:
    """Watchdog [MISSED]/[STUCK] strings injected by the alerting path."""
    return [
        _event(
            "R014",
            "MAJOR",
            None,
            "banking_watchdog",
            "WATCHDOG",
            "",
            alert,
            "the watchdog lost sight of a healthy run",
            runbook="RUNBOOK.md#a-run-failed-triage",
        )
        for alert in alerts
        if alert.startswith(("[MISSED]", "[STUCK]"))
    ]


def r015_watchdog_error(alerts: list[str]) -> list[dict[str, Any]]:
    """Watchdog [WATCHDOG-ERROR] strings: status unknown is never success."""
    return [
        _event(
            "R015",
            "CRITICAL",
            None,
            "banking_watchdog",
            "WATCHDOG",
            "",
            alert,
            "pipeline status unknown, investigate the watchdog",
            runbook="RUNBOOK.md#a-run-failed-triage",
        )
        for alert in alerts
        if alert.startswith("[WATCHDOG-ERROR]")
    ]


def r016_degraded_sections(context: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        _event(
            "R016",
            "MINOR",
            None,
            section,
            "REPORT",
            str(context["meta"].get("generated_at") or ""),
            f"{section} section degraded while collecting",
            "part of the report shows the section unavailable box",
            runbook=None,
        )
        for section in context.get("sections_failed", [])
    ]


def r017_skipped_tables(context: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        _event(
            "R017",
            "INFO",
            str(table["layer"]),
            f"{table['layer']}.{table['table']}",
            "DATA",
            _ended(context),
            "table skipped, no new data since last watermark",
            "none, the table refreshes once the source changes",
            runbook=None,
        )
        for table in context.get("tables", [])
        if table.get("status") == "SKIPPED"
    ]


RULES: list[Callable[[dict[str, Any]], list[dict[str, Any]]]] = [
    r001_failed_run,
    r002_partial_run,
    r003_dq_suite_fail,
    r004_publish_not_success,
    r005_final_attempt_error,
    r006_concurrency_resolved,
    r007_retried_tables,
    r008_dq_warning,
    r010_zero_row_full_load,
    r012_freshness_breach,
    r013_schema_drift,
    r016_degraded_sections,
    r017_skipped_tables,
]


def evaluate(
    context: dict[str, Any],
    *,
    volume_ratio: float = 0.5,
    duration_ratio: float = 1.5,
    watchdog_alerts: list[str] | None = None,
) -> dict[str, Any]:
    """Attach the event list and the run verdict to a copy of the context."""
    events: list[dict[str, Any]] = []
    for rule in RULES:
        events.extend(rule(context))
    events.extend(r009_volume_deviation(context, volume_ratio))
    events.extend(r011_duration_regression(context, duration_ratio))
    events.extend(r014_watchdog_alert(watchdog_alerts or []))
    events.extend(r015_watchdog_error(watchdog_alerts or []))
    events.sort(
        key=lambda e: (-_RANK[e["severity"]], e["rule"], e["subject"], e["event_id"])
    )

    if (context.get("run") or {}).get("status") == "RUNNING":
        severity = "UNKNOWN"
    else:
        severity = max(
            (e["severity"] for e in events),
            key=lambda s: _RANK[s],
            default="INFO",
        )
    result = dict(context)
    result["events"] = events
    result["verdict"] = {"severity": severity, "label": LABELS[severity]}
    return result
