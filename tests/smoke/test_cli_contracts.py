"""CLIs answer without touching any infrastructure."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.smoke

ROOT = Path(__file__).resolve().parents[2]

_CLI_CASES = [
    ["main.py", "--list"],
    ["scripts/run_jobs.py", "--help"],
    ["scripts/run_raw_tests.py", "--help"],
    ["scripts/run_staging_tests.py", "--help"],
    ["scripts/seed_watermarks.py", "--help"],
    ["src/jobs/publish_marts.py", "--help"],
]


@pytest.mark.parametrize("args", _CLI_CASES, ids=lambda a: a[0])
def test_cli_exits_zero_without_infrastructure(
    args: list[str], fake_env: dict[str, str]
) -> None:
    result = subprocess.run(
        [sys.executable, *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=90,
    )
    assert result.returncode == 0, result.stderr[-500:]
