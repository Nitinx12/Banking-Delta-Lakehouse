"""The TeX tier: every fixture compiles, the log is clean and the page budget holds."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from reports.scripts import build, compile as compile_mod, paths

pytestmark = pytest.mark.tex

PAGE_BUDGET = {"daily": (4, 8), "incident": (2, 5), "weekly": (4, 6)}


@pytest.fixture(autouse=True)
def _needs_latexmk() -> None:
    if not compile_mod.latexmk_available():
        pytest.skip("latexmk is not on PATH")


def _log_errors(kind: str) -> list[str]:
    """Lines the LaTeX log marks as an error."""
    log = paths.BUILD_DIR / f"{Path(paths.PDF_NAMES[kind]).stem}.log"
    if not log.is_file():
        return []
    return [
        line
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines()
        if line.lstrip().startswith("!")
    ]


@pytest.mark.parametrize("fixture", paths.fixture_paths(), ids=lambda p: p.stem)
def test_fixture_compiles_and_stays_in_the_page_budget(
    fixture: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("REPORT_OUTPUT_DIR", str(tmp_path / "output"))
    assert build.main(["--fixture", fixture.stem]) == build.EXIT_OK

    result = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert result["degraded"] is False
    assert result["path"] and Path(result["path"]).is_file()
    assert not _log_errors(result["kind"])

    low, high = PAGE_BUDGET[result["kind"]]
    assert result["pages"] is not None
    assert low <= result["pages"] <= high


@pytest.mark.parametrize("fixture", paths.fixture_paths(), ids=lambda p: p.stem)
def test_incident_pdf_compiles_when_the_run_is_bad(
    fixture: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REPORT_OUTPUT_DIR", str(tmp_path / "output"))
    assert build.main(["--fixture", fixture.stem]) == build.EXIT_OK

    incident = tmp_path / "output" / "incident.pdf"
    if not incident.is_file():
        pytest.skip("fixture has no incident verdict")
    low, high = PAGE_BUDGET["incident"]
    pages = compile_mod.page_count(paths.BUILD_DIR / "incident.log")
    assert pages is not None
    assert low <= pages <= high
