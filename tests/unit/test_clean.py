"""clean.py: caches or report artefacts, never the venv or .spark."""

from __future__ import annotations

from pathlib import Path

import pytest

from scripts import clean

pytestmark = pytest.mark.unit


def _repo_with_both(tmp_path: Path) -> Path:
    (tmp_path / ".pytest_cache").mkdir()
    (tmp_path / ".ruff_cache").mkdir()
    (tmp_path / "src" / "pkg" / "__pycache__").mkdir(parents=True)
    (tmp_path / ".venv" / "lib" / "__pycache__").mkdir(parents=True)
    (tmp_path / ".spark" / "jars" / "__pycache__").mkdir(parents=True)
    (tmp_path / "reports" / "build").mkdir(parents=True)
    (tmp_path / "reports" / "output").mkdir(parents=True)
    (tmp_path / "reports" / "figures").mkdir(parents=True)
    (tmp_path / "reports" / "figures" / "chart.pdf").write_text("pdf", encoding="utf-8")
    (tmp_path / "reports" / "figures" / "keep.png").write_text("png", encoding="utf-8")
    return tmp_path


def test_cache_paths_skip_the_venv_and_spark(tmp_path: Path) -> None:
    root = _repo_with_both(tmp_path)
    found = {path.relative_to(root).as_posix() for path in clean.cache_paths(root)}
    assert "src/pkg/__pycache__" in found
    assert ".pytest_cache" in found
    assert "coverage.xml" in found  # listed even when absent; remove() skips it
    assert not any(entry.startswith(".venv") for entry in found)
    assert not any(entry.startswith(".spark") for entry in found)


def test_report_paths_are_build_output_and_pdfs(tmp_path: Path) -> None:
    root = _repo_with_both(tmp_path)
    found = [path.relative_to(root).as_posix() for path in clean.report_paths(root)]
    assert found == ["reports/build", "reports/output", "reports/figures/chart.pdf"]


def test_remove_only_deletes_what_exists(tmp_path: Path) -> None:
    root = _repo_with_both(tmp_path)
    assert clean.remove(clean.report_paths(root)) == 3
    assert not (root / "reports" / "build").exists()
    assert (root / "reports" / "figures" / "keep.png").exists()


def test_main_cache_mode_leaves_reports_alone(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = _repo_with_both(tmp_path)
    monkeypatch.setattr(clean, "REPO_ROOT", root)
    assert clean.main([]) == 0
    assert not (root / ".pytest_cache").exists()
    assert not (root / "src" / "pkg" / "__pycache__").exists()
    assert (root / "reports" / "build").exists()
    assert (root / ".venv").exists()


def test_main_reports_mode_only_touches_reports(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = _repo_with_both(tmp_path)
    monkeypatch.setattr(clean, "REPO_ROOT", root)
    assert clean.main(["--reports"]) == 0
    assert not (root / "reports" / "build").exists()
    assert not (root / "reports" / "figures" / "chart.pdf").exists()
    assert (root / "reports" / "figures" / "keep.png").exists()
    assert (root / ".pytest_cache").exists()
