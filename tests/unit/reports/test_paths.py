"""Run keys, output paths and retention pruning must stay deterministic and safe."""

from __future__ import annotations

import os
import string
from datetime import datetime, timezone
from pathlib import Path

import pytest

from reports.scripts import paths

pytestmark = pytest.mark.unit


def test_run_key_reduces_dag_run_id_to_safe_chars() -> None:
    key = paths.run_key("scheduled__2026-10-20T20:30:00+00:00")
    assert key == "scheduled__2026_10_20T20_30_00_00_00"
    assert set(key) <= set(string.ascii_letters + string.digits + "_")


def test_run_key_falls_back_to_manual() -> None:
    assert paths.run_key(None) == "manual"
    assert paths.run_key("") == "manual"
    assert paths.run_key("///") == "manual"


def test_pdf_names_follow_the_report_kinds() -> None:
    assert paths.PDF_NAMES == {
        "daily": "report.pdf",
        "incident": "incident.pdf",
        "weekly": "weekly.pdf",
    }


def test_output_root_defaults_under_reports(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("REPORT_OUTPUT_DIR", raising=False)
    assert paths.output_root() == paths.REPORTS_DIR / "output"


def test_output_root_resolves_relative_env_against_project_root(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("REPORT_OUTPUT_DIR", "custom-out")
    assert paths.output_root() == paths.PROJECT_ROOT / "custom-out"


def test_run_and_pdf_paths_sit_under_output_root(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REPORT_OUTPUT_DIR", str(tmp_path))
    key = paths.run_key("scheduled__2026-10-20T20:30:00+00:00")
    assert paths.run_dir(key) == tmp_path / "runs" / key
    assert paths.pdf_path(key, "daily") == tmp_path / "runs" / key / "report.pdf"
    assert paths.latest_pdf("weekly") == tmp_path / "weekly.pdf"


def test_prune_runs_removes_only_folders_past_retention(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REPORT_OUTPUT_DIR", str(tmp_path))
    old = tmp_path / "runs" / "old_run"
    new = tmp_path / "runs" / "new_run"
    old.mkdir(parents=True)
    new.mkdir(parents=True)
    now = datetime(2026, 10, 26, tzinfo=timezone.utc)
    stale = now.timestamp() - 40 * 86400
    os.utime(old, (stale, stale))

    removed = paths.prune_runs(30, now=now)

    assert removed == [old]
    assert not old.exists()
    assert new.exists()


def test_prune_runs_is_a_no_op_without_run_folders(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REPORT_OUTPUT_DIR", str(tmp_path))
    assert paths.prune_runs(30) == []


def test_fixture_paths_lists_every_fixture_sorted() -> None:
    names = [path.name for path in paths.fixture_paths()]
    assert names == [
        "critical_failed_run.json",
        "healthy.json",
        "major_dq_fail.json",
        "minor_retry.json",
        "weekly.json",
    ]


def test_retention_days_reads_env_with_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("REPORT_RETENTION_DAYS", raising=False)
    assert paths.retention_days() == 30
    monkeypatch.setenv("REPORT_RETENTION_DAYS", "7")
    assert paths.retention_days() == 7
