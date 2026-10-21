"""report.yaml and slo.yaml must keep chapter sets and freshness windows stable."""

from __future__ import annotations

import re

import pytest
import yaml

from reports.scripts import paths

pytestmark = pytest.mark.unit

_REPORT = yaml.safe_load(
    (paths.REPORTS_DIR / "config" / "report.yaml").read_text(encoding="utf-8")
)
_SLO = yaml.safe_load(
    (paths.REPORTS_DIR / "config" / "slo.yaml").read_text(encoding="utf-8")
)
_KINDS = ["daily", "incident", "weekly"]
# Chapter names as listed in docs/REPORTING.md section 5.
_CHAPTERS = {
    "summary",
    "flow",
    "timeline",
    "volumes",
    "dq",
    "freshness",
    "incidents",
    "trends",
    "appendix",
}


def test_report_config_basics() -> None:
    assert _REPORT["schema_version"] == 1
    assert _REPORT["timezone"] == "Asia/Kolkata"
    assert _REPORT["trend_runs"] == 14


def test_kinds_match_the_documented_set() -> None:
    assert sorted(_REPORT["kinds"]) == _KINDS


@pytest.mark.parametrize("kind", _KINDS)
def test_chapters_are_known_and_ordered(kind: str) -> None:
    chapters = _REPORT["kinds"][kind]["chapters"]
    assert chapters
    assert len(chapters) == len(set(chapters)), f"{kind}: duplicate chapter"
    assert set(chapters) <= _CHAPTERS, f"{kind}: unknown chapter"


@pytest.mark.parametrize("kind", _KINDS)
def test_drop_when_empty_is_a_subset_of_chapters(kind: str) -> None:
    spec = _REPORT["kinds"][kind]
    assert set(spec.get("drop_when_empty", [])) <= set(spec["chapters"])


def test_thresholds_are_the_documented_defaults() -> None:
    thresholds = _REPORT["thresholds"]
    assert thresholds["volume_deviation_ratio"] == 0.5
    assert thresholds["duration_regression_ratio"] == 1.5
    assert thresholds["freshness_default_window"] == "PT24H"
    assert thresholds["max_message_chars"] == 300


def test_slo_yaml_covers_tables_without_a_contract() -> None:
    assert _SLO["schema_version"] == 1
    assert _SLO["default_window"] == "PT24H"
    assert _SLO["default_severity"] in {"WARNING", "ERROR"}
    # contracts/ has accounts, customers, support_tickets and transactions.
    assert set(_SLO["tables"]) == {
        "branches",
        "cards",
        "employees",
        "loans",
        "loan_payments",
        "card_transactions",
    }


@pytest.mark.parametrize("table", sorted(_SLO["tables"]))
def test_slo_entries_look_like_contract_windows(table: str) -> None:
    entry = _SLO["tables"][table]
    assert re.fullmatch(r"PT[0-9]+[HMS]", entry["window"]), table
    assert entry["severity"] in {"WARNING", "ERROR"}, table
