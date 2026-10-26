"""run_jobs must bound a hung extract and never leave an orphan JVM behind."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import run_jobs  # noqa: E402


class _FakeProc:
    """Stands in for subprocess.Popen: returns (or raises) one outcome per attempt."""

    def __init__(self, outcomes: list[int | subprocess.TimeoutExpired]) -> None:
        self._outcomes = list(outcomes)

    def wait(self, timeout: float | None = None) -> int:  # noqa: ARG002 - mirrors Popen
        outcome = self._outcomes.pop(0)
        if isinstance(outcome, subprocess.TimeoutExpired):
            raise outcome
        return outcome


def _timeout(cmd: str) -> subprocess.TimeoutExpired:
    return subprocess.TimeoutExpired(cmd, run_jobs.EXTRACT_TIMEOUT_SECONDS)


def test_hung_job_is_killed_and_retried(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A job that exceeds the deadline is killed with its tree and gets one retry."""
    procs: list[_FakeProc] = [
        _FakeProc([_timeout("job")]),
        _FakeProc([0]),
    ]
    kills: list[int] = []

    monkeypatch.setattr(
        run_jobs.subprocess, "Popen", lambda *args, **kwargs: procs.pop(0)
    )
    monkeypatch.setattr(run_jobs, "_kill_tree", lambda proc: kills.append(id(proc)))
    monkeypatch.setattr(run_jobs.time, "sleep", lambda seconds: None)

    assert run_jobs.run_job("mongo", []) == 0
    assert not procs, "both attempts must have been consumed"
    assert len(kills) == 1, "the hung attempt must be killed exactly once"


def test_persistent_failure_is_reported_after_one_retry(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A deterministic failure retries once, then its exit code is returned."""
    procs: list[_FakeProc] = [_FakeProc([7]), _FakeProc([7])]

    monkeypatch.setattr(
        run_jobs.subprocess, "Popen", lambda *args, **kwargs: procs.pop(0)
    )
    monkeypatch.setattr(run_jobs, "_kill_tree", lambda proc: None)
    monkeypatch.setattr(run_jobs.time, "sleep", lambda seconds: None)

    assert run_jobs.run_job("databricks", []) == 7
    assert not procs, "the retry must have been consumed"
