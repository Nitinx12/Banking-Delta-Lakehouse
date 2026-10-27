"""The Windows batch runner mirrors every Makefile target, and ci stays hermetic."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.smoke

ROOT = Path(__file__).resolve().parents[2]

_CI_FORBIDDEN = (
    "sql-smoke",
    "integration",
    "smoke-live",
    "spark-smoke",
    "daily",
    "publish",
)


def _make_targets() -> set[str]:
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    return set(re.findall(r"^([a-zA-Z][\w-]*):", text, re.MULTILINE)) - {"help"}


def test_batch_runner_implements_every_make_target() -> None:
    bat = (ROOT / "tasks.bat").read_text(encoding="utf-8").lower()
    missing = sorted(t for t in _make_targets() if f":t_{t}" not in bat)
    assert not missing, f"tasks.bat is missing targets: {missing}"


def test_ci_target_is_hermetic() -> None:
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    ci_block = re.search(r"^ci:.*(?:\n\t.*)*", text, re.MULTILINE)
    assert ci_block, "Makefile has no ci target"
    for forbidden in _CI_FORBIDDEN:
        assert forbidden not in ci_block.group(0), f"ci must not run {forbidden}"
