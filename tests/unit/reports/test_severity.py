"""Rules R001-R017: every fixture keeps its verdict, every rule fires and stays quiet."""

from __future__ import annotations

import json
from typing import Any

import pytest

from reports.scripts import severity
from reports.scripts.paths import FIXTURES_DIR, fixture_paths

pytestmark = pytest.mark.unit

_VERDICTS = {
    "healthy": ("INFO", "HEALTHY"),
    "minor_retry": ("MINOR", "ATTENTION"),
    "major_dq_fail": ("MAJOR", "ACTION REQUIRED"),
    "critical_failed_run": ("CRITICAL", "INCIDENT"),
    "weekly": ("MINOR", "ATTENTION"),
}


def _fixture(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES_DIR / f"{name}.json").read_text(encoding="utf-8"))


def _context(**overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "meta": {"dag_id": "banking_delta_daily", "generated_at": ""},
        "run": {"status": "SUCCESS"},
        "tables": [],
        "dq": [],
        "errors": [],
        "freshness": [],
        "trends": [],
        "sections_failed": [],
    }
    base.update(overrides)
    return base


def _rules(result: dict[str, Any]) -> set[str]:
    return {event["rule"] for event in result["events"]}


@pytest.mark.parametrize(
    ("name", "expected"), sorted(_VERDICTS.items()), ids=sorted(_VERDICTS)
)
def test_every_fixture_keeps_its_verdict(name: str, expected: tuple[str, str]) -> None:
    result = severity.evaluate(_fixture(name))
    assert (result["verdict"]["severity"], result["verdict"]["label"]) == expected


def test_fixture_paths_cover_the_documented_set() -> None:
    assert [p.stem for p in fixture_paths()] == sorted(_VERDICTS)


@pytest.mark.parametrize("name", sorted(_VERDICTS))
def test_fixture_events_are_sorted_and_unique(name: str) -> None:
    result = severity.evaluate(_fixture(name))
    ids = [event["event_id"] for event in result["events"]]
    assert len(ids) == len(set(ids))
    ranks = [severity._RANK[event["severity"]] for event in result["events"]]
    assert ranks == sorted(ranks, reverse=True)


def test_r001_r002_run_status_rules() -> None:
    failed = severity.evaluate(_context(run={"status": "FAILED", "failed_tables": 3}))
    assert "R001" in _rules(failed)
    assert failed["verdict"]["severity"] == "CRITICAL"
    partial = severity.evaluate(
        _context(run={"status": "PARTIAL", "failed_tables": 1, "total_tables": 10})
    )
    assert "R002" in _rules(partial)
    assert partial["verdict"]["severity"] == "MAJOR"
    running = severity.evaluate(_context(run={"status": "RUNNING"}))
    assert not _rules(running)
    assert running["verdict"]["severity"] == "UNKNOWN"


def test_r003_r008_r013_dq_rules() -> None:
    fail = severity.evaluate(
        _context(
            dq=[
                {
                    "layer": "raw",
                    "script_name": "01_lp_check_metadata_col.sql",
                    "status": "FAIL",
                    "violation_count": 3,
                }
            ]
        )
    )
    assert {"R003"} <= _rules(fail)
    schema = severity.evaluate(
        _context(
            dq=[
                {
                    "layer": "raw",
                    "script_name": "02_lp_schema_contract.sql",
                    "status": "FAIL",
                    "violation_count": 1,
                }
            ]
        )
    )
    assert "R013" in _rules(schema)
    warning = severity.evaluate(
        _context(
            dq=[
                {
                    "layer": "marts",
                    "script_name": "01_lp_check_row_counts.sql",
                    "status": "WARNING",
                    "violation_count": 1,
                }
            ]
        )
    )
    assert "R008" in _rules(warning)
    assert warning["verdict"]["severity"] == "MINOR"


def test_r004_publish_gate() -> None:
    result = severity.evaluate(
        _context(tables=[{"layer": "publish", "table": "marts.x", "status": "FAILED"}])
    )
    assert "R004" in _rules(result)
    assert result["verdict"]["severity"] == "MAJOR"
    quiet = severity.evaluate(
        _context(tables=[{"layer": "publish", "table": "marts.x", "status": "SUCCESS"}])
    )
    assert "R004" not in _rules(quiet)


def test_r004_fires_when_published_rows_differ_from_the_source() -> None:
    result = severity.evaluate(
        _context(
            tables=[
                {
                    "layer": "publish",
                    "table": "marts.x",
                    "status": "SUCCESS",
                    "rows_extracted": 50000,
                    "rows_landed": 47200,
                }
            ]
        )
    )
    assert "R004" in _rules(result)
    assert result["verdict"]["severity"] == "MAJOR"
    matching = severity.evaluate(
        _context(
            tables=[
                {
                    "layer": "publish",
                    "table": "marts.x",
                    "status": "SUCCESS",
                    "rows_extracted": 50000,
                    "rows_landed": 50000,
                }
            ]
        )
    )
    assert "R004" not in _rules(matching)


def test_r005_r006_error_rules() -> None:
    failed = severity.evaluate(
        _context(
            run={"status": "FAILED"},
            errors=[{"category": "CONNECTION", "severity": "CRITICAL"}],
        )
    )
    assert "R005" in _rules(failed)
    retry = severity.evaluate(
        _context(
            run={"status": "SUCCESS"},
            errors=[{"category": "CONCURRENCY", "severity": "MINOR"}],
        )
    )
    assert "R006" in _rules(retry)
    assert "R005" not in _rules(retry)
    spark_success = severity.evaluate(
        _context(
            run={"status": "SUCCESS"},
            errors=[{"category": "SPARK", "severity": "MINOR"}],
        )
    )
    assert not {"R005", "R006"} & _rules(spark_success)


def test_r007_retries() -> None:
    result = severity.evaluate(
        _context(tables=[{"layer": "raw", "table": "branches", "attempts": 2}])
    )
    assert "R007" in _rules(result)
    assert result["verdict"]["severity"] == "MINOR"


def test_r009_volume_deviation() -> None:
    trends = [
        {"status": "SUCCESS", "rows_landed": 50000},
        {"status": "SUCCESS", "rows_landed": 51000},
        {"status": "SUCCESS", "rows_landed": 1000},
    ]
    result = severity.evaluate(_context(trends=trends))
    assert "R009" in _rules(result)
    quiet = severity.evaluate(
        _context(trends=trends[:-1] + [{"status": "SUCCESS", "rows_landed": 50500}])
    )
    assert "R009" not in _rules(quiet)


def test_r010_zero_row_full_load() -> None:
    result = severity.evaluate(
        _context(
            tables=[
                {
                    "layer": "raw",
                    "table": "customers",
                    "status": "SUCCESS",
                    "rows_landed": 0,
                }
            ]
        )
    )
    assert "R010" in _rules(result)
    assert result["verdict"]["severity"] == "MAJOR"


def test_r011_duration_regression() -> None:
    trends = [
        {"status": "SUCCESS", "rows_landed": 10, "duration_s": 3000},
        {"status": "SUCCESS", "rows_landed": 10, "duration_s": 3100},
        {"status": "SUCCESS", "rows_landed": 10, "duration_s": 6000},
    ]
    result = severity.evaluate(_context(trends=trends))
    assert "R011" in _rules(result)
    quiet = severity.evaluate(
        _context(
            trends=trends[:-1]
            + [{"status": "SUCCESS", "rows_landed": 10, "duration_s": 3200}]
        )
    )
    assert "R011" not in _rules(quiet)


def test_r012_freshness_severities() -> None:
    warning = severity.evaluate(
        _context(
            freshness=[
                {
                    "table": "branches",
                    "age_s": 200000,
                    "window": "PT24H",
                    "breached": True,
                    "severity": "WARNING",
                }
            ]
        )
    )
    assert "R012" in _rules(warning)
    assert warning["verdict"]["severity"] == "MINOR"
    error = severity.evaluate(
        _context(
            freshness=[
                {
                    "table": "branches",
                    "age_s": 200000,
                    "window": "PT24H",
                    "breached": True,
                    "severity": "ERROR",
                }
            ]
        )
    )
    assert error["verdict"]["severity"] == "MAJOR"
    fresh = severity.evaluate(
        _context(
            freshness=[
                {"table": "branches", "age_s": 10, "window": "PT24H", "breached": False}
            ]
        )
    )
    assert "R012" not in _rules(fresh)


def test_r014_r015_watchdog_strings() -> None:
    missed = severity.evaluate(
        _context(), watchdog_alerts=["[MISSED] banking_delta_daily"]
    )
    assert "R014" in _rules(missed)
    assert missed["verdict"]["severity"] == "MAJOR"
    broken = severity.evaluate(_context(), watchdog_alerts=["[WATCHDOG-ERROR] boom"])
    assert "R015" in _rules(broken)
    assert broken["verdict"]["severity"] == "CRITICAL"
    info = severity.evaluate(_context(), watchdog_alerts=["[OK] all good"])
    assert not {"R014", "R015"} & _rules(info)


def test_r016_degraded_sections() -> None:
    result = severity.evaluate(_context(sections_failed=["freshness"]))
    assert "R016" in _rules(result)
    assert result["verdict"]["severity"] == "MINOR"


def test_r017_skipped_tables_are_info() -> None:
    result = severity.evaluate(
        _context(tables=[{"layer": "raw", "table": "branches", "status": "SKIPPED"}])
    )
    assert "R017" in _rules(result)
    assert result["verdict"]["severity"] == "INFO"


def test_healthy_context_without_events_is_healthy() -> None:
    result = severity.evaluate(_context())
    assert result["events"] == []
    assert result["verdict"] == {"severity": "INFO", "label": "HEALTHY"}
