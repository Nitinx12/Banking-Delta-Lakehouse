"""Unit tests for scripts/run_notebooks.py (nbconvert orchestration)."""

from __future__ import annotations

import io
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import run_notebooks  # noqa: E402 - script path is set above


class _Proc:
    def __init__(
        self, code: int = 0, stderr: str = "", exc: BaseException | None = None
    ) -> None:
        self.pid = 4242
        self.stderr = io.StringIO(stderr)
        self.code = code
        self.exc = exc
        self.waited = 0

    def wait(self, timeout: float | None = None) -> int:
        self.waited += 1
        if self.exc is not None:
            raise self.exc
        return self.code


@pytest.fixture
def notebook(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(run_notebooks, "NOTEBOOK_DIR", tmp_path)
    (tmp_path / "mysql.ipynb").write_text("{}", encoding="utf-8")
    return tmp_path


class TestKillTree:
    def test_windows_uses_taskkill(self, monkeypatch: pytest.MonkeyPatch) -> None:
        proc = _Proc()
        commands: list[list[str]] = []
        monkeypatch.setattr(
            run_notebooks.subprocess,
            "run",
            lambda cmd, **kw: commands.append(cmd),
        )

        run_notebooks._kill_tree(proc)

        assert commands == [["taskkill", "/PID", "4242", "/T", "/F"]]
        assert proc.waited == 1

    def test_posix_kills_process_group(self, monkeypatch: pytest.MonkeyPatch) -> None:
        proc = _Proc()
        killed: list[tuple[int, int]] = []
        shim = SimpleNamespace(
            name="posix",
            environ=run_notebooks.os.environ,
            getpgid=lambda pid: pid,
            killpg=lambda pgid, sig: killed.append((pgid, sig)),
        )
        monkeypatch.setattr(run_notebooks, "os", shim)
        monkeypatch.setattr(run_notebooks, "signal", SimpleNamespace(SIGKILL=9))

        run_notebooks._kill_tree(proc)

        assert killed == [(4242, 9)]

    def test_dead_process_group_is_ignored(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        proc = _Proc()

        def _missing(pid):
            raise ProcessLookupError

        shim = SimpleNamespace(
            name="posix",
            environ=run_notebooks.os.environ,
            getpgid=_missing,
            killpg=lambda pgid, sig: None,
        )
        monkeypatch.setattr(run_notebooks, "os", shim)
        monkeypatch.setattr(run_notebooks, "signal", SimpleNamespace(SIGKILL=9))

        run_notebooks._kill_tree(proc)

        assert proc.waited == 1


class TestRunNotebook:
    def test_missing_notebook_returns_two(
        self, notebook: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        assert run_notebooks.run_notebook("ghost", None, 5) == 2

    def test_inplace_success_returns_zero(
        self, notebook: Path, monkeypatch: pytest.MonkeyPatch, capsys
    ) -> None:
        proc = _Proc(code=0, stderr="real output\nCurveZMQ noise\n")
        commands: list[list[str]] = []
        monkeypatch.setattr(
            run_notebooks.subprocess,
            "Popen",
            lambda cmd, **kw: commands.append(cmd) or proc,
        )

        code = run_notebooks.run_notebook("mysql", None, 5)

        assert code == 0
        assert "--inplace" in commands[0]
        assert commands[0][-1].endswith("mysql.ipynb")
        captured = capsys.readouterr()
        assert "real output" in captured.err
        assert "CurveZMQ" not in captured.err
        assert proc.waited == 1

    def test_output_dir_writes_copy(
        self, notebook: Path, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        proc = _Proc(code=0)
        commands: list[list[str]] = []
        monkeypatch.setattr(
            run_notebooks.subprocess,
            "Popen",
            lambda cmd, **kw: commands.append(cmd) or proc,
        )

        code = run_notebooks.run_notebook("mysql", tmp_path / "out", 5)

        assert code == 0
        cmd = commands[0]
        assert "--inplace" not in cmd
        assert cmd[cmd.index("--output-dir") + 1] == str(tmp_path / "out")

    def test_timeout_kills_tree_and_returns_124(
        self, notebook: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        proc = _Proc(exc=subprocess.TimeoutExpired(cmd="x", timeout=1))
        killed: list[_Proc] = []
        monkeypatch.setattr(run_notebooks.subprocess, "Popen", lambda cmd, **kw: proc)
        monkeypatch.setattr(run_notebooks, "_kill_tree", lambda p: killed.append(p))

        assert run_notebooks.run_notebook("mysql", None, 1) == 124
        assert killed == [proc]

    def test_keyboard_interrupt_kills_tree_and_reraises(
        self, notebook: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        proc = _Proc(exc=KeyboardInterrupt())
        killed: list[_Proc] = []
        monkeypatch.setattr(run_notebooks.subprocess, "Popen", lambda cmd, **kw: proc)
        monkeypatch.setattr(run_notebooks, "_kill_tree", lambda p: killed.append(p))

        with pytest.raises(KeyboardInterrupt):
            run_notebooks.run_notebook("mysql", None, 1)
        assert killed == [proc]


class TestMain:
    def _patch(
        self,
        monkeypatch: pytest.MonkeyPatch,
        outcomes: dict[str, int | BaseException],
    ) -> list[str]:
        calls: list[str] = []

        def _run(name, output_dir, timeout):
            calls.append(name)
            outcome = outcomes.get(name, 0)
            if isinstance(outcome, BaseException):
                raise outcome
            return outcome

        monkeypatch.setattr(run_notebooks, "run_notebook", _run)
        return calls

    def test_all_success_returns_zero(self, monkeypatch: pytest.MonkeyPatch) -> None:
        self._patch(monkeypatch, {"a": 0, "b": 0})

        assert run_notebooks.main(["--notebooks", "a", "b"]) == 0

    def test_failure_stops_unless_keep_going(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        calls = self._patch(monkeypatch, {"a": 1, "b": 0})

        assert run_notebooks.main(["--notebooks", "a", "b"]) == 1
        assert calls == ["a"]

    def test_keep_going_runs_every_notebook(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        calls = self._patch(monkeypatch, {"a": 1, "b": 0})

        assert run_notebooks.main(["--notebooks", "a", "b", "--keep-going"]) == 1
        assert calls == ["a", "b"]

    def test_interrupt_marks_result_and_stops(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        calls = self._patch(monkeypatch, {"a": KeyboardInterrupt()})

        assert run_notebooks.main(["--notebooks", "a", "b"]) == 1
        assert calls == ["a"]

    def test_output_dir_is_created(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        self._patch(monkeypatch, {"a": 0})
        out = tmp_path / "reports"

        assert run_notebooks.main(["--notebooks", "a", "--output-dir", str(out)]) == 0
        assert out.is_dir()

    def test_defaults_to_every_notebook(self, monkeypatch: pytest.MonkeyPatch) -> None:
        calls = self._patch(
            monkeypatch, {name: 0 for name in run_notebooks.DEFAULT_NOTEBOOKS}
        )

        assert run_notebooks.main([]) == 0
        assert calls == list(run_notebooks.DEFAULT_NOTEBOOKS)
