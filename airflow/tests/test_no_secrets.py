"""No secrets committed under airflow/ (exclude the *.example template)."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

AIRFLOW_DIR = Path(__file__).resolve().parent.parent

pytestmark = pytest.mark.smoke

SECRET_PATTERNS = [
    re.compile(r"(?i)password\s*[:=]\s*['\"](?!\$\{)[^'\"]+['\"]"),
    re.compile(
        r"(?i)(api[_-]?key|secret|token)\s*[:=]\s*['\"](?!\$\{)[^'\"]{12,}['\"]"
    ),
    re.compile(r"-----BEGIN [A-Z ]+-----"),
    re.compile(r"\b[A-Za-z0-9+/]{60,}={0,2}\b"),
]

SKIP_SUFFIXES = {".example", ".md", ".j2", ".lock", ".png", ".jpg"}
SKIP_DIRS = {"__pycache__", ".ruff_cache", "logs", ".venv"}


def _iter_files():
    for path in AIRFLOW_DIR.rglob("*"):
        if not path.is_file():
            continue
        if path.name.startswith(".env"):  # git-ignored env files hold real secrets
            continue
        if path.suffix in SKIP_SUFFIXES:
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        yield path


def test_no_secret_literals_in_airflow_sources():
    offenders: list[str] = []
    for path in _iter_files():
        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for pattern in SECRET_PATTERNS:
            if pattern.search(content):
                offenders.append(f"{path.relative_to(AIRFLOW_DIR)}: {pattern.pattern}")
    assert offenders == [], f"possible secrets found: {offenders}"
