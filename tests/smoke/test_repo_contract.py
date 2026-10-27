"""Repo wiring: required files, pytest markers, hermetic ci, no tracked .env."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.smoke

ROOT = Path(__file__).resolve().parents[2]

_REQUIRED_FILES = [
    "AGENTS.md",
    "Makefile",
    "pyproject.toml",
    ".env.example",
    ".pre-commit-config.yaml",
    ".githooks/commit-msg",
    ".githooks/pre-commit",
    ".githooks/pre-push",
]

_MARKERS = ["unit", "smoke", "spark", "integration", "live"]

_CI_FORBIDDEN = (
    "sql-smoke",
    "integration",
    "smoke-live",
    "spark-smoke",
    "daily",
    "publish",
)


@pytest.mark.parametrize("relative", _REQUIRED_FILES, ids=lambda p: p.lstrip("."))
def test_required_file_exists(relative: str) -> None:
    assert (ROOT / relative).is_file(), f"missing: {relative}"


def test_pytest_markers_are_registered() -> None:
    text = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    for marker in _MARKERS:
        assert re.search(rf'"{marker}:', text), f"marker not registered: {marker}"


def test_ci_target_is_hermetic() -> None:
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    ci_line = re.search(r"^ci:.*(?:\n\t.*)*", text, re.MULTILINE)
    assert ci_line, "Makefile has no ci target"
    for forbidden in _CI_FORBIDDEN:
        assert forbidden not in ci_line.group(0), f"ci must not run {forbidden}"


def test_env_file_is_not_tracked_by_git() -> None:
    result = subprocess.run(
        ["git", "ls-files", "--", ".env"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
    assert not result.stdout.strip(), ".env must never be committed"
