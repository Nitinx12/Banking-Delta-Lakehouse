"""Defects D1 to D10 of docs/REPORT_REDESIGN.md as consistency tests on every fixture."""

from __future__ import annotations

import copy
import json
import re
import statistics
from pathlib import Path
from typing import Any

import jsonschema
import pytest
from matplotlib.figure import Figure

from reports.scripts import build, charts, paths, severity

pytestmark = pytest.mark.unit

_NAMES = ["healthy", "minor_retry", "major_dq_fail", "critical_failed_run", "weekly"]
_CHARTED = {"healthy", "major_dq_fail"}
_SCHEMA = json.loads(paths.CONTEXT_SCHEMA.read_text(encoding="utf-8"))


def _fixture(name: str) -> dict[str, Any]:
    return json.loads((paths.FIXTURES_DIR / f"{name}.json").read_text(encoding="utf-8"))


def _flat(tex: str) -> str:
    return tex.replace(r"\allowbreak{}", "")


def _runbook_hits(tex: str) -> int:
    return _flat(tex).replace(r"\#", "#").count("RUNBOOK.md#a-run-failed-triage")


def _row_labels(figure: Figure) -> list[str]:
    return [tick.get_text() for tick in figure.axes[0].get_yticklabels()]


def _heatmap_cells(figure: Figure) -> dict[tuple[str, str], str]:
    cells: dict[tuple[str, str], str] = {}
    for text in figure.axes[0].texts:
        content = text.get_text()
        if content not in {"PASS", "WARNING", "FAIL"}:
            continue
        x_value, y_value = text.get_position()
        cells[(int(x_value - 0.5), int(y_value - 0.5))] = content
    return cells


@pytest.fixture(scope="module")
def built(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Any]:
    """Render every fixture once; chapters as text, context as evaluated json."""
    root = tmp_path_factory.mktemp("consistency")
    captured: dict[str, Any] = {}
    mp = pytest.MonkeyPatch()
    try:
        mp.setattr("reports.scripts.paths.BUILD_DIR", root / "build")
        mp.setattr("reports.scripts.paths.FIGURES_DIR", root / "figures")
        mp.setattr("reports.scripts.paths.context_path", lambda: root / "context.json")
        mp.setenv("REPORT_OUTPUT_DIR", str(root / "output"))
        for name in _NAMES:
            argv = ["--fixture", name, "--no-pdf"]
            if name not in _CHARTED:
                argv.append("--no-charts")
            assert build.main(argv) == build.EXIT_OK, name
            captured[name] = {
                "tex": {
                    path.name: path.read_text(encoding="utf-8")
                    for path in sorted((root / "build").glob("*.tex"))
                },
                "context": json.loads(
                    (root / "context.json").read_text(encoding="utf-8")
                ),
            }
    finally:
        mp.undo()
    return captured


def _chapter(built: dict[str, Any], name: str, chapter: str) -> str:
    return built[name]["tex"][chapter]


def _context(built: dict[str, Any], name: str) -> dict[str, Any]:
    return built[name]["context"]


def _build_tmp(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    context: dict[str, Any],
    name: str,
) -> tuple[dict[str, str], dict[str, Any]]:
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir(parents=True, exist_ok=True)
    (fixtures / f"{name}.json").write_text(json.dumps(context), encoding="utf-8")
    monkeypatch.setattr("reports.scripts.paths.FIXTURES_DIR", fixtures)
    monkeypatch.setattr("reports.scripts.paths.BUILD_DIR", tmp_path / "build")
    monkeypatch.setattr("reports.scripts.paths.FIGURES_DIR", tmp_path / "figures")
    monkeypatch.setattr(
        "reports.scripts.paths.context_path", lambda: tmp_path / "context.json"
    )
    monkeypatch.setenv("REPORT_OUTPUT_DIR", str(tmp_path / "output"))
    code = build.main(["--fixture", name, "--no-pdf", "--no-charts"])
    assert code == build.EXIT_OK, name
    chapters = {
        path.name: path.read_text(encoding="utf-8")
        for path in sorted((tmp_path / "build").glob("*.tex"))
    }
    evaluated = json.loads((tmp_path / "context.json").read_text(encoding="utf-8"))
    return chapters, evaluated


def test_schema_requires_the_phase_one_fields() -> None:
    for field in ("kpis", "next_actions"):
        broken = copy.deepcopy(_fixture("healthy"))
        broken.pop(field, None)
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(broken, _SCHEMA)


def test_schema_requires_the_verdict_sentences() -> None:
    broken = copy.deepcopy(_fixture("healthy"))
    for field in ("headline", "consequence"):
        broken["verdict"].pop(field, None)
        with pytest.raises(jsonschema.ValidationError):
            jsonschema.validate(broken, _SCHEMA)


def test_schema_requires_the_timeline_and_label_fields() -> None:
    broken = copy.deepcopy(_fixture("healthy"))
    broken["steps"][1].pop("evidence", None)
    broken["steps"][1].pop("start_offset_s", None)
    broken["steps"][1].pop("end_offset_s", None)
    broken["tables"][0].pop("label", None)
    broken["tables"][0].pop("median_rows", None)
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(broken, _SCHEMA)


def test_d1_kpis_count_the_table_list(built: dict[str, Any]) -> None:
    for name in _NAMES:
        context = _context(built, name)
        tables = context["tables"]
        ok = sum(1 for table in tables if table["status"] == "SUCCESS")
        failed = sum(1 for table in tables if table["status"] == "FAILED")
        expected = {
            "total": len(tables),
            "ok": ok,
            "failed": failed,
            "skipped": len(tables) - ok - failed,
        }
        assert context["kpis"]["tables"] == expected, name


def test_d1_appendix_prints_the_same_table_counts(built: dict[str, Any]) -> None:
    for name in _NAMES:
        counts = _context(built, name)["kpis"]["tables"]
        appendix = _chapter(built, name, "09_appendix.tex")
        pattern = (
            rf"Tables\s*&\s*{counts['ok']}\s+succeeded,\s*{counts['failed']}\s+failed,"
            rf"\s*{counts['skipped']}\s+skipped"
        )
        assert re.search(pattern, appendix), name


def test_d1_run_status_messages_count_the_table_list() -> None:
    context = _fixture("critical_failed_run")
    context["run"].update(
        {
            "status": "FAILED",
            "total_tables": 10,
            "successful_tables": 3,
            "failed_tables": 7,
            "skipped_tables": 0,
        }
    )
    result = severity.evaluate(context)
    counts = result["kpis"]["tables"]
    event = next(event for event in result["events"] if event["rule"] == "R001")
    assert f"{counts['failed']} of {counts['total']} tables failed" in event["message"]


def test_d1_run_row_drift_is_flagged_and_never_printed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    context = _fixture("healthy")
    context["run"].update(
        {
            "total_tables": 10,
            "successful_tables": 10,
            "failed_tables": 0,
            "skipped_tables": 0,
        }
    )
    chapters, evaluated = _build_tmp(tmp_path, monkeypatch, context, "drift")
    assert any(event["rule"] == "R018" for event in evaluated["events"])
    counts = evaluated["kpis"]["tables"]
    appendix = chapters["09_appendix.tex"]
    assert f"{counts['ok']} succeeded" in appendix
    assert "10 succeeded" not in appendix


def test_d2_rows_kpi_is_the_raw_layer_alone(built: dict[str, Any]) -> None:
    for name in _NAMES:
        context = _context(built, name)
        raw_rows = [
            table["rows_landed"]
            for table in context["tables"]
            if table["layer"] == "raw" and table["rows_landed"] is not None
        ]
        published_rows = [
            table["rows_landed"]
            for table in context["tables"]
            if table["layer"] == "publish" and table["rows_landed"] is not None
        ]
        assert context["kpis"]["rows"]["raw"] == (sum(raw_rows) if raw_rows else None)
        published = sum(published_rows) if published_rows else None
        assert context["kpis"]["rows"]["published"] == published


def test_d2_rows_card_shows_the_raw_total(built: dict[str, Any]) -> None:
    summary = _chapter(built, "healthy", "01_summary.tex")
    assert r"2\,500" in summary


def test_d2_r009_and_the_rows_kpi_share_one_definition(
    built: dict[str, Any],
) -> None:
    for name in _NAMES:
        context = _context(built, name)
        volume_events = [e for e in context["events"] if e["rule"] == "R009"]
        if not volume_events:
            continue
        raw = context["kpis"]["rows"]["raw"]
        assert f"rows_landed={raw}" in volume_events[0]["message"], name


def test_d3_dq_kpi_counts_warnings_separately() -> None:
    context = _fixture("healthy")
    context["dq"] = [
        {
            "layer": "raw",
            "script_name": "a.sql",
            "status": "PASS",
            "violation_count": 0,
        },
        {
            "layer": "raw",
            "script_name": "b.sql",
            "status": "WARNING",
            "violation_count": 1,
        },
        {
            "layer": "raw",
            "script_name": "c.sql",
            "status": "FAIL",
            "violation_count": 2,
        },
    ]
    result = severity.evaluate(context)
    assert result["kpis"]["dq"] == {"passed": 1, "warnings": 1, "failed": 1, "total": 3}


def test_d3_heatmap_cells_equal_the_dq_list(built: dict[str, Any]) -> None:
    for name in _NAMES:
        dq = _context(built, name)["dq"]
        if not dq:
            continue
        layers = sorted({row["layer"] for row in dq})
        scripts = sorted({row["script_name"] for row in dq})
        cells = _heatmap_cells(charts.dq_heatmap(dq))
        expected = {
            (layers.index(row["layer"]), scripts.index(row["script_name"])): row[
                "status"
            ]
            for row in dq
        }
        assert cells == expected, name


def test_d3_flip_one_status_moves_every_consumer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    context = copy.deepcopy(_fixture("healthy"))
    context["dq"][0]["status"] = "FAIL"
    context["dq"][0]["violation_count"] = 7
    chapters, evaluated = _build_tmp(tmp_path, monkeypatch, context, "flipped")
    assert evaluated["kpis"]["dq"] == {
        "passed": 2,
        "warnings": 0,
        "failed": 1,
        "total": 3,
    }
    assert any(event["rule"] == "R003" for event in evaluated["events"])
    assert evaluated["verdict"]["severity"] == "MAJOR"
    assert r"\statusbanner{bad}" in chapters["01_summary.tex"]
    assert "FAIL" in chapters["05_dq.tex"]
    heatmap = _heatmap_cells(charts.dq_heatmap(evaluated["dq"]))
    assert "FAIL" in heatmap.values()


def test_d4_every_step_states_its_evidence(built: dict[str, Any]) -> None:
    for name in _NAMES:
        steps = _context(built, name)["steps"]
        assert steps, name
        for step in steps:
            assert isinstance(step.get("evidence"), bool), f"{name}:{step['name']}"
            if step["evidence"]:
                assert step["start_offset_s"] is not None, step["name"]
                assert step["end_offset_s"] is not None, step["name"]
                assert 0 <= step["start_offset_s"] <= step["end_offset_s"], step["name"]
            else:
                assert step["start_offset_s"] is None, step["name"]
                assert step["end_offset_s"] is None, step["name"]


def test_d4_timeline_draws_only_evidenced_steps_at_their_offsets() -> None:
    steps = _fixture("healthy")["steps"]
    evidenced = [step for step in steps if step.get("evidence")]
    with_duration = [step for step in steps if step.get("duration_s") is not None]
    assert with_duration == evidenced
    figure = charts.task_timeline(steps)
    bars = figure.axes[0].patches
    assert len(bars) == len(evidenced)
    for bar, step in zip(bars, reversed(evidenced), strict=True):
        assert bar.get_x() == step["start_offset_s"]
        assert bar.get_width() == step["end_offset_s"] - step["start_offset_s"]


def test_d4_idle_steps_leave_no_bar(built: dict[str, Any]) -> None:
    steps = _context(built, "critical_failed_run")["steps"]
    evidenced = [step for step in steps if step.get("evidence")]
    idle = [step for step in steps if not step.get("evidence")]
    assert evidenced and idle
    figure = charts.task_timeline(steps)
    assert len(figure.axes[0].patches) == len(evidenced)


def test_d5_idle_dq_chapter_names_the_reason(built: dict[str, Any]) -> None:
    dq_chapter = _chapter(built, "critical_failed_run", "05_dq.tex")
    assert r"\sectionunavailable" not in dq_chapter
    assert r"\sectionidle{Data Quality}" in dq_chapter
    assert "extract_mongo" in dq_chapter


def test_d5_empty_dq_card_is_idle_not_green(built: dict[str, Any]) -> None:
    summary = _chapter(built, "critical_failed_run", "01_summary.tex")
    card = re.search(r"\\kpicard\{DQ checks passed\}[^)]*?\{(ok|idle)\}", summary)
    assert card is not None
    assert card.group(1) == "idle"


def test_d6_no_placeholder_above_a_populated_event_table(
    built: dict[str, Any],
) -> None:
    for name in _NAMES:
        context = _context(built, name)
        if not context["events"]:
            continue
        incidents = _chapter(built, name, "07_incidents.tex")
        assert "tabular" in incidents, name
        if context["errors"]:
            if name in _CHARTED:
                assert "error_categories" in incidents, name
            continue
        assert "error_categories" not in incidents, name


def test_d7_volumes_rows_are_labeled_layer_table() -> None:
    tables = _fixture("healthy")["tables"]
    labels = _row_labels(charts.volumes_dumbbell(tables, None))
    assert labels == [f"{t['layer']}.{t['table']}" for t in reversed(tables)]


def test_d7_freshness_rows_are_labeled() -> None:
    freshness = _fixture("healthy")["freshness"]
    labels = _row_labels(charts.freshness_bullet(freshness))
    assert labels == [f"raw.{row['table']}" for row in reversed(freshness)]


def test_d7_publish_rows_carry_their_layer() -> None:
    tables = _fixture("healthy")["tables"]
    labels = _row_labels(charts.publish_reconcile(tables))
    assert labels == [f"{t['layer']}.{t['table']}" for t in tables]


def test_d8_attention_names_its_subjects(built: dict[str, Any]) -> None:
    summary = _chapter(built, "critical_failed_run", "01_summary.tex")
    flat = _flat(summary)
    assert "Severity & Subject &" in summary
    assert "R007 x2" in flat
    assert r"raw.card\_transactions" in flat
    assert r"raw.support\_tickets" in flat


def test_d8_one_runbook_pointer_per_action(built: dict[str, Any]) -> None:
    summary = _chapter(built, "critical_failed_run", "01_summary.tex")
    assert _runbook_hits(summary) == 1


def test_d9_duration_kpi_trails_the_median_and_keeps_the_sign(
    built: dict[str, Any],
) -> None:
    context = _context(built, "healthy")
    history = [row["duration_s"] for row in _fixture("healthy")["trends"][:-1]]
    duration = context["kpis"]["duration"]
    assert duration["median_s"] == int(statistics.median(history))
    expected = int(
        round((context["run"]["duration_s"] / duration["median_s"] - 1) * 100)
    )
    assert duration["delta_pct"] == expected
    assert duration["delta_pct"] == 1
    summary = _chapter(built, "healthy", "01_summary.tex")
    assert r"+1\% vs median 52m 20s" in summary


def test_d10_regeneration_prints_the_kind_being_built(
    built: dict[str, Any],
) -> None:
    incident = _flat(_chapter(built, "critical_failed_run", "09_appendix.tex"))
    assert "--kind incident" in incident
    assert "--kind daily" not in incident
    weekly = _flat(_chapter(built, "weekly", "09_appendix.tex"))
    assert "--kind weekly" in weekly


def test_verdict_sentences_exist_on_every_fixture(built: dict[str, Any]) -> None:
    for name in _NAMES:
        verdict = _context(built, name)["verdict"]
        assert 0 < len(verdict["headline"]) <= 200, name
        assert 0 < len(verdict["consequence"]) <= 300, name


def test_verdict_is_the_worst_event(built: dict[str, Any]) -> None:
    for name in _NAMES:
        context = _context(built, name)
        expected = max(
            (event["severity"] for event in context["events"]),
            key=lambda severity_name: severity._RANK[severity_name],
            default="INFO",
        )
        assert context["verdict"]["severity"] == expected, name


def test_next_actions_are_ordered_runbook_actions(built: dict[str, Any]) -> None:
    for name in _NAMES:
        actions = _context(built, name)["next_actions"]
        assert len(actions) <= 4, name
        pairs = [(action["runbook"], action["rule"]) for action in actions]
        assert len(pairs) == len(set(pairs)), name
        for action in actions:
            assert {"rule", "severity", "runbook", "subjects", "text"} <= set(action)
            assert action["subjects"] and action["runbook"]
            assert action["runbook"] in action["text"]
            assert len(action["text"]) <= 300
        ranks = [severity._RANK[action["severity"]] for action in actions]
        assert ranks == sorted(ranks, reverse=True), name
    assert _context(built, "critical_failed_run")["next_actions"]
