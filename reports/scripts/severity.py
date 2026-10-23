# Rule engine R001-R018: turns collected context sections into events and a verdict.
from __future__ import annotations

import statistics
from collections import defaultdict
from typing import Any, Callable

from . import kpis, paths
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
    counts = kpis.table_counts(context)
    return [
        _event(
            "R001",
            "CRITICAL",
            None,
            str(context["meta"]["dag_id"]),
            "UNKNOWN",
            _ended(context),
            f"run status FAILED, {counts['failed']} of {counts['total']} tables failed",
            "nothing was published, yesterday's marts stand",
        )
    ]


def r002_partial_run(context: dict[str, Any]) -> list[dict[str, Any]]:
    run = context.get("run") or {}
    if run.get("status") != "PARTIAL":
        return []
    counts = kpis.table_counts(context)
    return [
        _event(
            "R002",
            "MAJOR",
            None,
            str(context["meta"]["dag_id"]),
            "DATA",
            _ended(context),
            f"run status PARTIAL, {counts['failed']} of "
            f"{counts['total']} tables failed",
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
    current = kpis.raw_rows(context)
    if current is None:
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


def r018_run_row_drift(context: dict[str, Any]) -> list[dict[str, Any]]:
    """Run row counters that disagree with the table list; report counts use the list."""
    run = context.get("run") or {}
    if not context.get("tables") or run.get("total_tables") is None:
        return []
    counts = kpis.table_counts(context)
    pairs = (
        ("total_tables", "total"),
        ("successful_tables", "ok"),
        ("failed_tables", "failed"),
        ("skipped_tables", "skipped"),
    )
    drift = [
        f"{key} {run.get(key)}!={counts[alias]}"
        for key, alias in pairs
        if run.get(key) is not None
        and counts[alias] is not None
        and run.get(key) != counts[alias]
    ]
    if not drift:
        return []
    return [
        _event(
            "R018",
            "MINOR",
            None,
            str(context["meta"]["dag_id"]),
            "REPORT",
            _ended(context),
            "run row disagrees with the table list: " + ", ".join(drift),
            "printed counts follow the table list, audit.pipeline_runs is stale",
            runbook=None,
        )
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
    r018_run_row_drift,
]


def _fill(template: str, fields: dict[str, str]) -> str:
    """Fill one wording template; unknown placeholders become empty."""
    try:
        return str(template).format_map(defaultdict(str, fields))
    except (KeyError, IndexError, ValueError):
        return str(template)


def _sentence_fields(
    context: dict[str, Any], events: list[dict[str, Any]], severity: str
) -> dict[str, str]:
    top = events[0] if events else {}
    return {
        "rule": str(top.get("rule") or ""),
        "subject": str(top.get("subject") or ""),
        "layer": str(top.get("layer") or "pipeline"),
        "severity": severity,
        "label": LABELS[severity],
        "impact": str(top.get("impact") or ""),
    }


def _next_actions(
    events: list[dict[str, Any]], template: str, cap: int = 4
) -> list[dict[str, Any]]:
    """One action per runbook anchor and rule, worst severity first."""
    grouped: dict[tuple[str, str], dict[str, Any]] = {}
    for event in events:
        runbook = event.get("runbook")
        if not runbook:
            continue
        key = (str(runbook), str(event["rule"]))
        group = grouped.get(key)
        if group is None:
            grouped[key] = {
                "rule": event["rule"],
                "severity": event["severity"],
                "runbook": str(runbook),
                "subjects": [str(event["subject"])],
            }
        elif event["subject"] not in group["subjects"]:
            group["subjects"].append(str(event["subject"]))
    actions = list(grouped.values())[:cap]
    for action in actions:
        subjects = action["subjects"]
        while True:
            text = _fill(
                template,
                {
                    "severity": str(action["severity"]),
                    "rule": str(action["rule"]),
                    "subjects": ", ".join(subjects),
                    "runbook": action["runbook"],
                },
            )
            if len(text) <= 300 or len(subjects) == 1:
                break
            subjects.pop()
        action["text"] = text[:300]
    return actions


def evaluate(
    context: dict[str, Any],
    *,
    volume_ratio: float = 0.5,
    duration_ratio: float = 1.5,
    watchdog_alerts: list[str] | None = None,
    wording: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Attach events, KPIs, next actions and the run verdict to a copy of the context."""
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
    if wording is None:
        wording = paths.load_report_config().get("wording") or {}
    verdict_wording = wording.get("verdict") or {}
    fields = _sentence_fields(context, events, severity)
    headline = _fill(
        str((verdict_wording.get("headline") or {}).get(severity) or ""), fields
    )
    consequence = _fill(
        str((verdict_wording.get("consequence") or {}).get(severity) or ""), fields
    )
    result = dict(context)
    result["events"] = events
    result["verdict"] = {
        "severity": severity,
        "label": LABELS[severity],
        "headline": headline[:200],
        "consequence": consequence[:300],
    }
    result["kpis"] = kpis.compute(context)
    result["next_actions"] = _next_actions(
        events, str(wording.get("next_action") or "")
    )
    return result
