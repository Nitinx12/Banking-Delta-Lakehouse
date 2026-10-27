"""Every required env var is documented in .env.example."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.smoke

ROOT = Path(__file__).resolve().parents[2]
_SOURCES = ["src", "scripts", "airflow"]


def test_env_example_covers_every_required_variable() -> None:
    used: set[str] = set()
    for base in _SOURCES:
        for py in (ROOT / base).rglob("*.py"):
            if "__pycache__" in py.parts:
                continue
            used |= set(
                re.findall(
                    r"require\(\s*[\"'](\w+)[\"']", py.read_text(encoding="utf-8")
                )
            )

    example = (ROOT / ".env.example").read_text(encoding="utf-8")
    missing = sorted(
        var for var in used if not re.search(rf"^{var}=", example, re.MULTILINE)
    )
    assert not missing, f"add to .env.example: {missing}"
