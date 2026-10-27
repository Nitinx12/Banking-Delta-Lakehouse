"""The help printer lists every Makefile target and needs no awk."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from scripts import make_help

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]


def _makefile_text() -> str:
    return (ROOT / "Makefile").read_text(encoding="utf-8")


def test_help_lists_every_declared_target():
    text = _makefile_text()
    listed = {name for _, name, _ in make_help.targets(text)}
    declared = set(re.findall(r"^([a-zA-Z][\w-]*):", text, re.MULTILINE))
    assert declared
    assert declared <= listed, sorted(declared - listed)


def test_help_keeps_the_groups_and_the_usage_line():
    rendered = make_help.render(_makefile_text())
    assert rendered.startswith('Usage: make <target> [ARGS="..."]')
    assert "\nStatic checks\n" in rendered
    assert "\nGate\n" in rendered


def test_help_target_does_not_call_awk():
    block = re.search(r"^help:.*(?:\n\t.*)*", _makefile_text(), re.MULTILINE)
    assert block, "Makefile has no help target"
    assert "awk" not in block.group(0)
