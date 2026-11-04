"""run_jobs runs one subprocess per source with timeout, retry and ordering."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import run_jobs  # noqa: E402 - script path is set above


class _Proc:
    def __init__(self, code: int = 0, exc: BaseException | None = None) -> None:
        self.pid = 4242
        self.code = code
        self.exc = exc
        self.waited = 0

    def wait(self, timeout: float | None = None) -> int:
        self.waited += 1
        if self.exc is not None:
            raise self.exc
        return self.code


@pytest.fixture
def no_sleep(monkeypatch: pytest.MonkeyPatch) -> list[float]:
    sleeps: list[float] = []
    monkeypatch.setattr(run_jobs.time, "sleep", sleeps.append)
    return sleeps


class TestKillTree:
    def test_windows_uses_taskkill(self, monkeypatch: pytest.MonkeyPatch) -> None:
        proc = _Proc()
        commands: list[list[str]] = []
        monkeypatch.setattr(
            run_jobs,
            "os",
            SimpleNamespace(name="nt", environ=run_jobs.os.environ),
        )
        monkeypatch.setattr(
            run_jobs.subprocess, "run", lambda cmd, **kw: commands.append(cmd)
        )

        run_jobs._kill_tree(proc)

        assert commands == [["taskkill", "/PID", "4242", "/T", "/F"]]
        assert proc.waited == 1

    def test_posix_kills_the_process_group(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        proc = _Proc()
        killed: list[tuple[int, int]] = []
        monkeypatch.setattr(
            run_jobs,
            "os",
            SimpleNamespace(
                name="posix",
                environ=run_jobs.os.environ,
                getpgid=lambda pid: pid,
                killpg=lambda pgid, sig: killed.append((pgid, sig)),
            ),
        )
        monkeypatch.setattr(run_jobs, "signal", SimpleNamespace(SIGKILL=9))

        run_jobs._kill_tree(proc)

        assert killed == [(4242, 9)]
        assert proc.waited == 1


class TestRunJob:
    def test_success_on_first_attempt(
        self, monkeypatch: pytest.MonkeyPatch, no_sleep: list[float]
    ) -> None:
        commands: list[list[str]] = []
        monkeypatch.setattr(
            run_jobs.subprocess,
            "Popen",
            lambda cmd, **kw: commands.append(cmd) or _Proc(code=0),
        )

        assert run_jobs.run_job("mysql", ["--tables", "accounts"]) == 0
        assert commands[0][1].endswith("extract_mysql.py")
        assert commands[0][2:] == ["--tables", "accounts"]
        assert no_sleep == []

    def test_failure_is_retried_once_then_succeeds(
        self, monkeypatch: pytest.MonkeyPatch, no_sleep: list[float]
    ) -> None:
        procs = iter([_Proc(code=3), _Proc(code=0)])
        monkeypatch.setattr(run_jobs.subprocess, "Popen", lambda cmd, **kw: next(procs))
        monkeypatch.setattr(run_jobs, "JOB_RETRY_BACKOFF_SECONDS", 7)

        assert run_jobs.run_job("mongo", []) == 0
        assert no_sleep == [7]

    def test_failure_on_both_attempts_returns_the_code(
        self, monkeypatch: pytest.MonkeyPatch, no_sleep: list[float]
    ) -> None:
        monkeypatch.setattr(
            run_jobs.subprocess, "Popen", lambda cmd, **kw: _Proc(code=9)
        )

        assert run_jobs.run_job("databricks", []) == 9
        assert no_sleep == [run_jobs.JOB_RETRY_BACKOFF_SECONDS]

    def test_zero_backoff_skips_the_sleep(
        self, monkeypatch: pytest.MonkeyPatch, no_sleep: list[float]
    ) -> None:
        monkeypatch.setattr(
            run_jobs.subprocess, "Popen", lambda cmd, **kw: _Proc(code=1)
        )
        monkeypatch.setattr(run_jobs, "JOB_RETRY_BACKOFF_SECONDS", 0)

        assert run_jobs.run_job("mysql", []) == 1
        assert no_sleep == []

    def test_timeout_kills_the_tree_and_returns_124(
        self, monkeypatch: pytest.MonkeyPatch, no_sleep: list[float]
    ) -> None:
        proc = _Proc(exc=subprocess.TimeoutExpired(cmd="x", timeout=1))
        killed: list[_Proc] = []
        monkeypatch.setattr(run_jobs.subprocess, "Popen", lambda cmd, **kw: proc)
        monkeypatch.setattr(run_jobs, "_kill_tree", lambda p: killed.append(p))

        assert run_jobs.run_job("mysql", []) == 124
        assert killed == [proc, proc]

    def test_keyboard_interrupt_kills_and_reraises(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        proc = _Proc(exc=KeyboardInterrupt())
        killed: list[_Proc] = []
        monkeypatch.setattr(run_jobs.subprocess, "Popen", lambda cmd, **kw: proc)
        monkeypatch.setattr(run_jobs, "_kill_tree", lambda p: killed.append(p))

        with pytest.raises(KeyboardInterrupt):
            run_jobs.run_job("mysql", [])
        assert killed == [proc]


class TestMain:
    def test_runs_sources_in_canonical_order(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        calls: list[str] = []
        monkeypatch.setattr(
            run_jobs, "run_job", lambda source, extra: calls.append(source) or 0
        )

        assert run_jobs.main(["--sources", "mysql", "mongo"]) == 0
        assert calls == ["mongo", "mysql"]

    def test_stops_at_first_failure_unless_keep_going(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        calls: list[str] = []

        def _run(source: str, extra: list[str]) -> int:
            calls.append(source)
            return 2

        monkeypatch.setattr(run_jobs, "run_job", _run)

        assert run_jobs.main(["--sources", "mongo", "mysql"]) == 1
        assert calls == ["mongo"]

        calls.clear()
        assert run_jobs.main(["--sources", "mongo", "mysql", "--keep-going"]) == 1
        assert calls == ["mongo", "mysql"]

    def test_interrupt_marks_the_source_and_stops(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        calls: list[str] = []

        def _run(source: str, extra: list[str]) -> int:
            calls.append(source)
            raise KeyboardInterrupt

        monkeypatch.setattr(run_jobs, "run_job", _run)

        assert run_jobs.main(["--sources", "mongo", "mysql"]) == 1
        assert calls == ["mongo"]

    def test_unknown_options_are_forwarded(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        seen: list[tuple[str, list[str]]] = []
        monkeypatch.setattr(
            run_jobs,
            "run_job",
            lambda source, extra: seen.append((source, extra)) or 0,
        )

        assert run_jobs.main(["extra-flag"]) == 0
        assert [source for source, _ in seen] == list(run_jobs.JOBS)
        assert all(extra == ["extra-flag"] for _, extra in seen)


class _FakeProc:
    """Stands in for subprocess.Popen: returns (or raises) one outcome per attempt."""

    def __init__(self, outcomes: list[int | subprocess.TimeoutExpired]) -> None:
        self._outcomes = list(outcomes)

    def wait(self, timeout: float | None = None) -> int:
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
