"""Summary logic and rendering: no DB, no network, no row values."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from banking_airflow import notify, summary

pytestmark = pytest.mark.unit

ALL_OK = {
    "preflight": "SUCCESS",
    "extract_mongo": "SUCCESS",
    "extract_databricks": "SUCCESS",
    "extract_mysql": "SUCCESS",
    "raw_tests": "SUCCESS",
    "staging_load": "SUCCESS",
    "staging_tests": "SUCCESS",
    "analytics_load": "SUCCESS",
    "analytics_tests": "SUCCESS",
    "marts_load": "SUCCESS",
    "marts_tests": "SUCCESS",
    "publish": "SUCCESS",
}


def _meta():
    return {
        "run_id": "scheduled__2026-10-20T02:00",
        "dag_id": "banking_delta_daily",
        "run_date": "20 Oct 2026",
        "duration": "41m 12s",
        "trigger_type": "scheduled",
        "env": "production",
        "git_sha": "3fa9c1d",
        "base_url": "https://airflow.example.com",
    }


@pytest.mark.parametrize(
    ("states", "dag_state", "audit_status", "expected"),
    [
        (ALL_OK, "success", None, "SUCCESS"),
        (ALL_OK, "success", "SUCCESS", "SUCCESS"),
        (ALL_OK, "success", "PARTIAL", "PARTIAL"),
        (ALL_OK, "success", "FAILED", "FAILED"),
        ({**ALL_OK, "raw_tests": "FAILED"}, "failed", None, "FAILED"),
        ({**ALL_OK, "marts_tests": "UPSTREAM_FAILED"}, "failed", None, "FAILED"),
        ({**ALL_OK, "publish": "UPSTREAM_FAILED"}, "failed", None, "FAILED"),
        ({**ALL_OK, "publish": "RUNNING"}, "running", None, "UNKNOWN"),
        ({}, "", None, "UNKNOWN"),
    ],
)
def test_decide_status_truth_table(states, dag_state, audit_status, expected):
    assert summary.decide_status(states, dag_state, audit_status) == expected


def test_decide_status_never_reports_success_over_a_missing_step():
    partial = {k: "SUCCESS" for k in ALL_OK if k != "analytics_tests"}
    assert summary.decide_status(partial, "running") == "UNKNOWN"


def test_run_date_label_handles_none_logical_date():
    now = datetime(2026, 10, 20, 2, tzinfo=UTC)
    start = datetime(2026, 10, 20, 2, tzinfo=UTC)
    assert summary.run_date_label(None, start, now) == "20 Oct 2026"
    assert summary.run_date_label(None, None, now) == "20 Oct 2026"


def test_task_states_map_normalises_enums():
    class State:
        value = "failed"

    assert summary.task_states_from_context(
        {"task_states": {"raw_tests": State()}}
    ) == {"raw_tests": "FAILED"}


def test_failure_reasons_lists_only_failed_steps():
    states = {**ALL_OK, "raw_tests": "FAILED", "publish": "UPSTREAM_FAILED"}
    assert summary.failure_reasons(states) == ["raw_tests", "publish"]


def test_notes_flag_no_new_data_only_when_every_source_skipped():
    all_skipped = {
        **ALL_OK,
        "extract_mongo": "SKIPPED",
        "extract_databricks": "SKIPPED",
        "extract_mysql": "SKIPPED",
    }
    assert any("No new data" in n for n in summary.build_notes("SUCCESS", all_skipped))
    one_skipped = {**ALL_OK, "extract_mongo": "SKIPPED"}
    assert not any(
        "No new data" in n for n in summary.build_notes("SUCCESS", one_skipped)
    )


def test_subject_prefixes_status_and_run_date():
    assert summary.subject_for("FAILED", "20 Oct 2026").startswith(
        "[FAILED] Banking-Delta"
    )


def _empty_sections():
    return {
        name: summary.Section(lambda: None)
        for name in ("run", "tables", "errors", "dq", "latest_dq")
    }


def test_render_text_contains_steps_and_no_row_values():
    steps = summary.step_rows(ALL_OK, {})
    text = summary.render_text(
        _meta(), steps, _empty_sections(), ["note"], "[SUCCESS] x"
    )
    assert "raw_tests" in text
    assert "STEPS" in text and "NOTES" in text


def test_render_html_has_no_script_or_external_assets():
    steps = summary.step_rows(ALL_OK, {})
    html = summary.render_html(
        _meta(), steps, _empty_sections(), ["note"], "[SUCCESS] x"
    )
    lowered = html.lower()
    assert "<script" not in lowered
    assert "http://" not in lowered.replace("https://airflow.example.com", "")
    assert "src=" not in lowered


def test_build_and_send_uses_current_context(monkeypatch):
    sent = {}

    def fake_send(subject, html, text, to=None, attachments=None):
        sent["subject"] = subject
        sent["html"] = html
        sent["text"] = text
        sent["attachments"] = attachments

    monkeypatch.setattr(notify, "send_email", fake_send)
    _stub_audit(monkeypatch, task_states=dict(ALL_OK))

    class DagRun:
        run_id = "r1"
        start_date = datetime(2026, 10, 20, 2, tzinfo=UTC)
        end_date = datetime(2026, 10, 20, 2, 41, tzinfo=UTC)
        logical_date = None
        state = "success"
        run_type = "scheduled"

    class Dag:
        dag_id = "banking_delta_daily"

    context = {
        "dag": Dag(),
        "dag_run": DagRun(),
        "run_id": "r1",
        "task_states": dict(ALL_OK),
        "env": "production",
        "git_sha": "abc",
        "base_url": "https://airflow.example.com",
    }
    summary.build_and_send(context)
    assert sent["subject"].startswith("[SUCCESS]")
    assert "banking_delta_daily" in sent["html"]


def _stub_audit(
    monkeypatch,
    run=None,
    tables=None,
    errors=None,
    dq=None,
    latest=None,
    task_states=None,
):
    from banking_airflow import audit_reader

    monkeypatch.setattr(audit_reader, "pipeline_run", lambda *_a: run)
    monkeypatch.setattr(audit_reader, "table_runs", lambda *_a: tables or [])
    monkeypatch.setattr(audit_reader, "errors", lambda *_a: errors or [])
    monkeypatch.setattr(audit_reader, "dq_results", lambda *_a: dq or [])
    monkeypatch.setattr(audit_reader, "latest_dq", lambda *_a: latest or [])
    monkeypatch.setattr(audit_reader, "task_states", lambda *_a: task_states or {})


def test_collect_tables_maps_audit_columns(monkeypatch):
    _stub_audit(
        monkeypatch,
        tables=[
            {
                "airflow_task_id": "extract_mysql",
                "processing_layer": "raw",
                "source_table": "core.customers",
                "target_table": "raw.customers",
                "status": "SUCCESS",
                "attempt_number": 1,
                "rows_extracted": 120,
                "rows_landed": 120,
                "watermark_start": "2026-01-01",
                "watermark_end": "2026-06-01",
            }
        ],
    )
    rows = summary.collect_tables("banking_delta_daily", "r1")
    assert rows[0]["layer"] == "raw"
    assert rows[0]["rows_landed"] == 120
    assert rows[0]["bad"] is False


def test_collect_errors_flags_failed_attempts(monkeypatch):
    _stub_audit(
        monkeypatch,
        errors=[
            {
                "processing_layer": "raw",
                "source_table": "core.loans",
                "target_table": "raw.loans",
                "error_category": "DATA",
                "severity": "error",
                "retry_attempt": 2,
                "is_recoverable": False,
                "resolution_status": "open",
            }
        ],
    )
    rows = summary.collect_errors("banking_delta_daily", "r1")
    assert rows[0]["category"] == "DATA"
    assert rows[0]["retry_attempt"] == 2


def test_collect_dq_marks_failed_check(monkeypatch):
    _stub_audit(
        monkeypatch,
        dq=[
            {
                "check_name": "row_count_source_vs_landed",
                "status": "FAILED",
                "records_checked": 100,
                "records_failed": 5,
            }
        ],
    )
    rows = summary.collect_dq("banking_delta_daily", "r1")
    assert rows[0]["bad"] is True


def test_section_degrades_on_audit_error(monkeypatch):
    from banking_airflow import audit_reader

    def boom(*_a):
        raise RuntimeError("warehouse unreachable")

    monkeypatch.setattr(audit_reader, "table_runs", boom)
    section = summary.Section(summary.collect_tables, "dag", "run")
    assert section.data is None
    assert section.error == "RuntimeError"


def test_section_notes_report_unavailable_audit():
    def boom():
        raise RuntimeError("nope")

    sections = {
        "run": summary.Section(boom),
        "tables": summary.Section(lambda: []),
        "errors": summary.Section(lambda: []),
        "dq": summary.Section(lambda: []),
        "latest_dq": summary.Section(lambda: []),
    }
    notes = summary.section_notes(sections)
    assert any("unavailable" in n for n in notes)


class _FakeTI:
    """Stand-in for the Airflow 3 Task SDK's RuntimeTaskInstance."""

    def __init__(self, states=None, crumbs=None, fail=False):
        self._states = states or {}
        self._crumbs = crumbs or []
        self._fail = fail

    def get_task_states(self, dag_id, run_ids):
        if self._fail:
            raise RuntimeError("supervisor unreachable")
        return {run_id: dict(self._states) for run_id in run_ids}

    def get_task_breadcrumbs(self, dag_id, run_id):
        if self._fail:
            raise RuntimeError("supervisor unreachable")
        return list(self._crumbs)


def test_sdk_task_states_reads_run_map_and_normalises():
    ti = _FakeTI(states={"raw_tests": "success", "publish": None})
    assert summary.sdk_task_states({"ti": ti}, "d", "r1") == {
        "raw_tests": "SUCCESS",
        "publish": "",
    }


def test_sdk_task_states_degrades_to_empty():
    assert summary.sdk_task_states({"ti": _FakeTI(fail=True)}, "d", "r1") == {}
    assert summary.sdk_task_states({}, "d", "r1") == {}


def test_sdk_task_durations_formats_seconds():
    ti = _FakeTI(
        crumbs=[
            {"task_id": "extract_mongo", "state": "success", "duration": 2.4},
            {"task_id": "publish", "state": "success", "duration": 144.0},
            {"task_id": None, "duration": 5},
        ]
    )
    assert summary.sdk_task_durations({"ti": ti}, "d", "r1") == {
        "extract_mongo": "2s",
        "publish": "2m 24s",
    }


def test_collect_task_states_prefers_audit_and_fills_gaps(monkeypatch):
    _stub_audit(monkeypatch, task_states={"extract_mongo": "SKIPPED"})
    ti = _FakeTI(states=dict(ALL_OK))
    context = {"ti": ti, "task_states": {"extract_mysql": "SUCCESS"}}
    states = summary.collect_task_states(context, "banking_delta_daily", "r1")
    assert states["extract_mongo"] == "SKIPPED"
    assert set(states) == set(ALL_OK)


def test_step_rows_labels_missing_step_unknown():
    steps = summary.step_rows({"preflight": "SUCCESS"}, {})
    by_id = {s["task_id"]: s for s in steps}
    assert by_id["preflight"]["state"] == "SUCCESS"
    assert by_id["publish"]["state"] == "UNKNOWN"
    assert by_id["publish"]["bad"] is True


def _summary_context(monkeypatch, **extra):
    class DagRun:
        run_id = "r1"
        start_date = datetime(2026, 10, 20, 2, tzinfo=UTC)
        end_date = datetime(2026, 10, 20, 2, 41, tzinfo=UTC)
        logical_date = None
        state = "success"
        run_type = "scheduled"

    class Dag:
        dag_id = "banking_delta_daily"

    sent = {}

    def fake_send(subject, html, text, to=None, attachments=None):
        sent["subject"] = subject
        sent["text"] = text

    monkeypatch.setattr(notify, "send_email", fake_send)
    context = {
        "dag": Dag(),
        "dag_run": DagRun(),
        "run_id": "r1",
        "base_url": "https://airflow.example.com",
        **extra,
    }
    return context, sent


def test_build_and_send_success_with_live_sdk_states(monkeypatch):
    _stub_audit(
        monkeypatch,
        task_states={
            "extract_mongo": "SKIPPED",
            "extract_databricks": "SKIPPED",
            "extract_mysql": "SUCCESS",
        },
    )
    ti = _FakeTI(states=dict(ALL_OK))
    context, sent = _summary_context(monkeypatch, ti=ti)
    summary.build_and_send(context)
    assert sent["subject"].startswith("[SUCCESS]")
    assert "extract_mongo" in sent["text"]


def test_build_and_send_reports_unknown_when_states_missing(monkeypatch):
    _stub_audit(monkeypatch, task_states={"extract_mysql": "SUCCESS"})
    context, sent = _summary_context(monkeypatch)
    summary.build_and_send(context)
    assert sent["subject"].startswith("[UNKNOWN]")
    assert "Task states unavailable" in sent["text"]
