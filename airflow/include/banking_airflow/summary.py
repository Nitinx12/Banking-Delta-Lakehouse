"""Pipeline summary: task state plus the pipeline's own audit tables.

Sections degrade independently - a failed audit query drops that section but
never blocks the mail. The audit tables (audit.pipeline_runs, table_runs,
pipeline_errors, data_quality_results) are the same rows the extract runner and
publisher write, so the email and the pipeline agree. Emails carry counts,
names and statuses only, never row values.
"""

from __future__ import annotations

import logging
import os
from datetime import UTC, datetime
from typing import Any

try:
    from zoneinfo import ZoneInfo
except ImportError:
    from backports.zoneinfo import ZoneInfo

log = logging.getLogger("banking.airflow.summary")

REPORT_TZ = ZoneInfo(os.environ.get("REPORT_TIMEZONE", "Asia/Kolkata"))

CORE_STEPS: tuple[str, ...] = (
    "preflight",
    "extract_mongo",
    "extract_databricks",
    "extract_mysql",
    "raw_tests",
    "staging_load",
    "staging_tests",
    "analytics_load",
    "analytics_tests",
    "marts_load",
    "marts_tests",
    "publish",
)

STEP_SOURCE: dict[str, str] = {
    "extract_mongo": "mongo",
    "extract_databricks": "databricks",
    "extract_mysql": "mysql",
}

FAILED_STATES = {"FAILED", "UPSTREAM_FAILED"}
PENDING_STATES = {
    "",
    "NONE",
    "RUNNING",
    "QUEUED",
    "SCHEDULED",
    "DEFERRED",
    "RESTARTING",
}
TERMINAL_STATES = {"SUCCESS", "FAILED", "UPSTREAM_FAILED", "SKIPPED", "REMOVED"}
NON_SUMMARY_CORE_STEPS = tuple(
    s
    for s in CORE_STEPS
    if s not in ("finalize_audit", "build_report", "send_pipeline_summary")
)


def _state_name(value: Any) -> str:
    return getattr(value, "value", value) or ""


def _as_state_map(raw: Any) -> dict[str, str]:
    """Normalise context['task_states'] (best effort) to {task_id: STATE}."""
    if not hasattr(raw, "items"):
        return {}
    return {
        str(task_id): str(_state_name(value)).upper() for task_id, value in raw.items()
    }


def _as_mapping(row: Any) -> dict[str, Any]:
    if hasattr(row, "items"):
        return dict(row)
    return {}


def _detail(value: Any) -> dict[str, Any]:
    """Best-effort view of a task state: duration is unknown here, so leave it out."""
    return _as_mapping(value)


def _as_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _duration(start: Any, end: Any) -> str:
    try:
        if not start or not end:
            return "—"
        total = int((end - start).total_seconds())
    except (TypeError, AttributeError, ValueError):
        return "—"
    minutes, seconds = divmod(total, 60)
    return f"{minutes}m {seconds:02d}s" if minutes else f"{seconds}s"


def _watermark_to_display_tz(value: str | None) -> str | None:
    """Convert a canonical UTC watermark string to the report timezone for display.

    Input: 'YYYY-MM-DD HH:MM:SS[.ffffff]+00:00' (canonical UTC)
    Output: 'YYYY-MM-DD HH:MM:SS[.ffffff] IST' (or configured timezone)
    """
    if not value:
        return None
    try:
        # Parse as UTC
        dt = datetime.fromisoformat(value.replace("+00:00", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=UTC)
        # Convert to display timezone
        dt_local = dt.astimezone(REPORT_TZ)
        return dt_local.strftime("%Y-%m-%d %H:%M:%S %Z")
    except (ValueError, AttributeError):
        return value  # return as-is if parsing fails


class Section:
    """One collector result: data, or the error that stopped it."""

    def __init__(self, fn, *args) -> None:
        try:
            self.data = fn(*args)
            self.error = None
        except Exception as exc:  # noqa: BLE001 - one failing section must not block the mail
            self.data = None
            self.error = type(exc).__name__
            log.warning(
                "summary section %s failed: %s", getattr(fn, "__name__", fn), exc
            )


def run_date_label(logical_date: Any, start: Any, now: datetime) -> str:
    """DD Mon YYYY from the first real date; a manual AF3 run has logical_date=None."""
    stamp = logical_date or start or now
    try:
        return stamp.strftime("%d %b %Y")
    except (AttributeError, ValueError):
        return now.strftime("%d %b %Y")


def decide_status(
    task_states: dict[str, str],
    dag_run_state: Any = "",
    audit_status: str | None = None,
) -> str:
    """Single source of truth for the banner; never reports success over a failure.

    Terminal states: success | failed | upstream_failed | skipped | removed.
    Everything else, including a missing key, is non-terminal.

    Returns:
        FAILED  - any core step failed/upstream_failed, or dag_run_state=failed
        UNKNOWN - any core step (excl. summary tasks) missing or non-terminal
        PARTIAL - audit.pipeline_runs.status == PARTIAL
        SUCCESS - all core steps success and audit SUCCESS
    """
    if str(_state_name(dag_run_state)).lower() == "failed":
        return "FAILED"
    for task_id in CORE_STEPS:
        state = task_states.get(task_id)
        if state in FAILED_STATES:
            return "FAILED"
    # Missing or non-terminal state on a core step (excl. the summary tasks)
    for task_id in NON_SUMMARY_CORE_STEPS:
        state = task_states.get(task_id)
        if not state or state not in TERMINAL_STATES:
            return "UNKNOWN"
    # All core steps terminal - check audit status
    if audit_status == "PARTIAL":
        return "PARTIAL"
    if audit_status == "FAILED":
        return "FAILED"
    return "SUCCESS"


def failure_reasons(task_states: dict[str, str]) -> list[str]:
    return [t for t in CORE_STEPS if task_states.get(t) in FAILED_STATES]


def subject_for(status: str, run_date: str) -> str:
    return f"[{status}] Banking-Delta daily pipeline — {run_date}"


def task_states_from_context(context: dict[str, Any]) -> dict[str, str]:
    return _as_state_map(context.get("task_states"))


def step_rows(
    task_states: dict[str, str], details: dict[str, Any]
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for task_id in CORE_STEPS:
        state = task_states.get(task_id, "NOT_RUN")
        meta = details.get(task_id) or {}
        rows.append(
            {
                "task_id": task_id,
                "state": state,
                "duration": meta.get("duration", "—"),
                "try_number": meta.get("try_number"),
                "bad": state in FAILED_STATES
                or state in {"SKIPPED", "NOT_RUN"}
                or (state not in TERMINAL_STATES and state != ""),
            }
        )
    return rows


def build_notes(status: str, task_states: dict[str, str]) -> list[str]:
    notes: list[str] = []
    failed = failure_reasons(task_states)
    if failed:
        notes.append("Fix the cause, then clear and re-run: " + ", ".join(failed))
    skipped = [t for t in STEP_SOURCE if task_states.get(t) == "SKIPPED"]
    if len(skipped) == len(STEP_SOURCE):
        notes.append("No new data past the watermark for every incremental source.")
    if status == "SUCCESS":
        notes.append("All steps completed successfully.")
    elif status == "UNKNOWN":
        missing = [
            t
            for t in NON_SUMMARY_CORE_STEPS
            if not task_states.get(t) or task_states.get(t) not in TERMINAL_STATES
        ]
        notes.append(
            "Task states unavailable ({} of {}): {}".format(
                len(missing), len(NON_SUMMARY_CORE_STEPS), ", ".join(missing)
            )
        )
    elif status == "PARTIAL":
        notes.append("audit.pipeline_runs recorded this run as PARTIAL.")
    return notes


def collect_run(dag_id: str, run_id: str) -> dict[str, Any] | None:
    """The shared audit.pipeline_runs row for this DAG run (rollup counts)."""
    from banking_airflow import audit_reader

    return audit_reader.pipeline_run(dag_id, run_id)


def collect_tables(dag_id: str, run_id: str) -> list[dict[str, Any]]:
    """Per-table audit.table_runs rows: layer, counts, watermarks, status."""
    from banking_airflow import audit_reader

    rows: list[dict[str, Any]] = []
    for tr in audit_reader.table_runs(dag_id, run_id):
        rows.append(
            {
                "task_id": tr.get("airflow_task_id") or "—",
                "layer": tr.get("processing_layer") or "—",
                "source_table": tr.get("source_table") or "—",
                "target_table": tr.get("target_table") or "—",
                "status": tr.get("status") or "—",
                "attempt": _as_int(tr.get("attempt_number")),
                "rows_extracted": _as_int(tr.get("rows_extracted")),
                "rows_landed": _as_int(tr.get("rows_landed")),
                "watermark_start": tr.get("watermark_start"),
                "watermark_end": tr.get("watermark_end"),
                "bad": tr.get("status") == "FAILED",
            }
        )
    return rows


def collect_errors(dag_id: str, run_id: str) -> list[dict[str, Any]]:
    """audit.pipeline_errors for this run: category, severity, table, retry."""
    from banking_airflow import audit_reader

    return [
        {
            "layer": e.get("processing_layer") or "—",
            "source_table": e.get("source_table") or "—",
            "target_table": e.get("target_table") or "—",
            "category": e.get("error_category") or "—",
            "severity": e.get("severity") or "—",
            "retry_attempt": _as_int(e.get("retry_attempt")),
            "recoverable": e.get("is_recoverable"),
            "resolution": e.get("resolution_status") or "—",
        }
        for e in audit_reader.errors(dag_id, run_id)
    ]


def collect_dq(dag_id: str, run_id: str) -> list[dict[str, Any]]:
    """audit.data_quality_results for this run: check, status, failed counts."""
    from banking_airflow import audit_reader

    return [
        {
            "check_name": d.get("check_name") or "—",
            "status": d.get("status") or "—",
            "records_checked": _as_int(d.get("records_checked")),
            "records_failed": _as_int(d.get("records_failed")),
            "bad": d.get("status") == "FAILED",
        }
        for d in audit_reader.dq_results(dag_id, run_id)
    ]


def collect_latest_dq() -> list[dict[str, Any]]:
    """audit.v_dq_latest: the latest DQ verdict per layer/script (context)."""
    from banking_airflow import audit_reader

    return [
        {
            "layer": r.get("layer") or "—",
            "script_name": r.get("script_name") or "—",
            "status": r.get("status") or "—",
            "violation_count": _as_int(r.get("violation_count")),
            "bad": r.get("status") == "FAIL",
        }
        for r in audit_reader.latest_dq()
    ]


def build_and_send(context: dict[str, Any]) -> None:
    """Render and send the summary. Section failures degrade, never abort the mail."""
    from banking_airflow import notify
    from banking_airflow import audit_reader

    dag_run = context.get("dag_run")
    dag_id = getattr(context.get("dag"), "dag_id", "banking_delta_daily")
    run_id = context.get("run_id") or getattr(dag_run, "run_id", "")
    # Get task states from audit (source of truth in Airflow 3)
    task_states = audit_reader.task_states(dag_id, run_id)
    # Fallback to context task_states for backward compatibility
    context_states = task_states_from_context(context)
    # Merge: audit states take precedence, context states fill gaps
    for k, v in context_states.items():
        if k not in task_states:
            task_states[k] = v
    states_raw = context.get("task_states") or {}
    getter = getattr(states_raw, "get", lambda *_args: None)
    details = {t: _detail(getter(t)) for t in CORE_STEPS}

    sections = {
        "run": Section(collect_run, dag_id, run_id),
        "tables": Section(collect_tables, dag_id, run_id),
        "errors": Section(collect_errors, dag_id, run_id),
        "dq": Section(collect_dq, dag_id, run_id),
        "latest_dq": Section(collect_latest_dq),
    }

    start = getattr(dag_run, "start_date", None)
    end = getattr(dag_run, "end_date", None)
    # Get audit run status for decision
    audit_run = sections["run"].data
    audit_status = audit_run.get("status") if audit_run else None
    status = decide_status(task_states, getattr(dag_run, "state", ""), audit_status)
    run_date = run_date_label(
        getattr(dag_run, "logical_date", None), start, datetime.now(UTC)
    )

    run_meta = {
        "run_id": run_id,
        "dag_id": dag_id,
        "run_date": run_date,
        "duration": _duration(start, end),
        "trigger_type": str(_state_name(getattr(dag_run, "run_type", "manual"))),
        "env": os.environ.get("ENVIRONMENT", "unknown"),
        "git_sha": os.environ.get("GIT_SHA", "unknown")[:12],
        "base_url": str(context.get("base_url", "")).rstrip("/"),
    }

    steps = step_rows(task_states, details)
    notes = build_notes(status, task_states)
    notes += section_notes(sections)
    subject = subject_for(status, run_date)
    text = render_text(run_meta, steps, sections, notes, subject)
    html = render_html(run_meta, steps, sections, notes, subject)

    # Find report PDFs to attach
    attachments = _find_report_attachments(run_id, status)

    notify.send_email(subject, html, text, attachments=attachments)


def _find_report_attachments(run_id: str, status: str) -> list:
    """Locate the daily and incident PDFs for this run."""

    from reports.scripts.paths import output_root as report_output_root, run_key

    out_root = report_output_root()
    key = run_key(run_id)

    attachments = []

    # Daily report (always built)
    daily_path = out_root / "runs" / key / "report.pdf"
    if daily_path.exists():
        attachments.append(daily_path)

    # Incident report (built when any event is MAJOR or CRITICAL)
    incident_path = out_root / "runs" / key / "incident.pdf"
    if incident_path.exists():
        attachments.append(incident_path)

    # LaTeX source files
    for tex_file in (out_root / "runs" / key).glob("*.tex"):
        attachments.append(tex_file)

    return attachments


def section_notes(sections: dict[str, Section]) -> list[str]:
    """Flag any audit section that could not be read - the mail never hides it."""
    failed = [name for name, section in sections.items() if section.error]
    if failed:
        return [f"Audit section(s) unavailable this run: {', '.join(failed)}."]
    run = sections["run"].data
    if run and run.get("status") and run["status"] != "SUCCESS":
        return [f"audit.pipeline_runs recorded this run as {run['status']}."]
    return []


def _row_text(prefix: str, columns: list[tuple[str, Any]]) -> str:
    parts = [prefix]
    for label, value in columns:
        parts.append(f"{label}={value}")
    return "  " + " | ".join(parts)


def render_text(
    run_meta: dict[str, Any],
    steps: list[dict[str, Any]],
    sections: dict[str, Section],
    notes: list[str],
    subject: str,
) -> str:
    lines = [
        subject,
        f"Run: {run_meta['run_id']}  | {run_meta['duration']} | "
        f"trigger={run_meta['trigger_type']} | env={run_meta['env']} | build={run_meta['git_sha']}",
    ]
    if run_meta["base_url"]:
        lines.append(
            f"Open: {run_meta['base_url']}/dags/{run_meta['dag_id']}/runs/{run_meta['run_id']}"
        )

    lines += ["", "STEPS"]
    for step in steps:
        mark = "!" if step["bad"] else " "
        lines.append(
            f" {mark} {step['task_id']:<20} {step['state']:<16} {step['duration']}"
        )

    run = sections["run"].data
    if run:
        lines += ["", "PIPELINE RUN (audit.pipeline_runs)"]
        lines.append(
            _row_text(
                " ",
                [
                    ("status", run.get("status")),
                    ("total", run.get("total_tables")),
                    ("ok", run.get("successful_tables")),
                    ("failed", run.get("failed_tables")),
                    ("skipped", run.get("skipped_tables")),
                ],
            )
        )

    tables = sections["tables"].data or []
    lines += ["", f"TABLES (audit.table_runs, {len(tables)} attempt(s))"]
    for t in tables:
        mark = "!" if t["bad"] else " "
        wm_start = _watermark_to_display_tz(t["watermark_start"])
        wm_end = _watermark_to_display_tz(t["watermark_end"])
        lines.append(
            _row_text(
                mark,
                [
                    ("layer", t["layer"]),
                    ("source", t["source_table"]),
                    ("target", t["target_table"]),
                    ("status", t["status"]),
                    ("try", t["attempt"]),
                    ("extracted", t["rows_extracted"]),
                    ("landed", t["rows_landed"]),
                    (
                        "watermark",
                        f"{wm_start} -> {wm_end}" if wm_start or wm_end else None,
                    ),
                ],
            )
        )

    dq = sections["dq"].data or []
    lines += ["", f"DQ RESULTS this run (audit.data_quality_results, {len(dq)})"]
    for d in dq:
        mark = "!" if d["bad"] else " "
        lines.append(
            _row_text(
                mark,
                [
                    ("check", d["check_name"]),
                    ("status", d["status"]),
                    ("checked", d["records_checked"]),
                    ("failed", d["records_failed"]),
                ],
            )
        )

    latest = sections["latest_dq"].data or []
    lines += ["", f"LATEST DQ PER SCRIPT (audit.v_dq_latest, {len(latest)})"]
    for r in latest:
        mark = "!" if r["bad"] else " "
        lines.append(
            _row_text(
                mark,
                [
                    ("layer", r["layer"]),
                    ("script", r["script_name"]),
                    ("status", r["status"]),
                    ("violations", r["violation_count"]),
                ],
            )
        )

    errs = sections["errors"].data or []
    lines += ["", f"ERRORS (audit.pipeline_errors, {len(errs)})"]
    for e in errs:
        lines.append(
            _row_text(
                "!",
                [
                    ("layer", e["layer"]),
                    ("source", e["source_table"]),
                    ("category", e["category"]),
                    ("severity", e["severity"]),
                    ("retry", e["retry_attempt"]),
                    ("recoverable", e["recoverable"]),
                    ("resolution", e["resolution"]),
                ],
            )
        )

    lines += ["", "NOTES"]
    lines += [f"  {note}" for note in (notes or ["none"])]
    return "\n".join(lines)


def render_html(
    run_meta: dict[str, Any],
    steps: list[dict[str, Any]],
    sections: dict[str, Section],
    notes: list[str],
    subject: str,
) -> str:
    import html as html_mod

    def esc(value: Any) -> str:
        return html_mod.escape(str(value))

    def cell(value: Any) -> str:
        return f"<td>{esc(value)}</td>"

    note_items = "".join(f"<li>{esc(n)}</li>" for n in notes)

    def table(title: str, headers: list[str], rows: list[list[Any]]) -> str:
        head = "".join(f"<th>{esc(h)}</th>" for h in headers)
        body = "".join("<tr>" + "".join(cell(c) for c in row) + "</tr>" for row in rows)
        return (
            f"<h4>{esc(title)}</h4>"
            f"<table border='1' cellpadding='4' cellspacing='0'>"
            f"<tr>{head}</tr>{body}</table>"
        )

    blocks = [
        f"<h2>{esc(subject)}</h2>",
        f"<p>DAG {esc(run_meta['dag_id'])} | Run {esc(run_meta['run_id'])} | "
        f"{esc(run_meta['duration'])} | env={esc(run_meta['env'])} | "
        f"build={esc(run_meta['git_sha'])}</p>",
        table(
            "Steps",
            ["Step", "State", "Duration"],
            [[s["task_id"], s["state"], s["duration"]] for s in steps],
        ),
    ]

    run = sections["run"].data
    if run:
        blocks.append(
            table(
                "Pipeline run (audit.pipeline_runs)",
                ["Status", "Total", "OK", "Failed", "Skipped"],
                [
                    [
                        run.get("status"),
                        run.get("total_tables"),
                        run.get("successful_tables"),
                        run.get("failed_tables"),
                        run.get("skipped_tables"),
                    ]
                ],
            )
        )

    tables = sections["tables"].data or []
    blocks.append(
        table(
            f"Tables (audit.table_runs, {len(tables)})",
            [
                "Layer",
                "Source",
                "Target",
                "Status",
                "Try",
                "Extracted",
                "Landed",
                "Watermark",
            ],
            [
                [
                    t["layer"],
                    t["source_table"],
                    t["target_table"],
                    t["status"],
                    t["attempt"],
                    t["rows_extracted"],
                    t["rows_landed"],
                    f"{_watermark_to_display_tz(t['watermark_start'])} -> {_watermark_to_display_tz(t['watermark_end'])}"
                    if t["watermark_start"] or t["watermark_end"]
                    else "—",
                ]
                for t in tables
            ],
        )
    )

    dq = sections["dq"].data or []
    blocks.append(
        table(
            f"DQ results this run ({len(dq)})",
            ["Check", "Status", "Checked", "Failed"],
            [
                [
                    d["check_name"],
                    d["status"],
                    d["records_checked"],
                    d["records_failed"],
                ]
                for d in dq
            ],
        )
    )

    latest = sections["latest_dq"].data or []
    blocks.append(
        table(
            f"Latest DQ per script (audit.v_dq_latest, {len(latest)})",
            ["Layer", "Script", "Status", "Violations"],
            [
                [r["layer"], r["script_name"], r["status"], r["violation_count"]]
                for r in latest
            ],
        )
    )

    errs = sections["errors"].data or []
    blocks.append(
        table(
            f"Errors (audit.pipeline_errors, {len(errs)})",
            [
                "Layer",
                "Source",
                "Category",
                "Severity",
                "Retry",
                "Recoverable",
                "Resolution",
            ],
            [
                [
                    e["layer"],
                    e["source_table"],
                    e["category"],
                    e["severity"],
                    e["retry_attempt"],
                    e["recoverable"],
                    e["resolution"],
                ]
                for e in errs
            ],
        )
    )

    blocks.append(f"<h4>Notes</h4><ul>{note_items}</ul>")
    return "".join(blocks)
