"""Unit tests for the four schema DQ runners (raw/staging/analytics/marts are identical)."""

from __future__ import annotations

import importlib
import io
import sys
import uuid
from pathlib import Path

import pytest
from rich.console import Console

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

MODULES = [
    "run_raw_tests",
    "run_staging_tests",
    "run_analytics_tests",
    "run_marts_tests",
]


@pytest.fixture(params=MODULES)
def runner(request):
    return importlib.import_module(request.param)


class _Cursor:
    def __init__(self, conn: "_Conn") -> None:
        self.conn = conn

    def __enter__(self) -> "_Cursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query: str, params=None) -> None:
        self.conn.executed.append((query, params))
        if self.conn.emit_notices and not self.conn.notices:
            self.conn.notices.extend(self.conn.emit_notices)
        if self.conn.raise_on_execute:
            raise RuntimeError("procedure failed: check violated")


class _Conn:
    def __init__(self, emit=(), raise_on_execute: bool = False) -> None:
        self.notices: list[str] = []
        self.emit_notices = list(emit)
        self.executed: list[tuple] = []
        self.autocommit = False
        self.closed = False
        self.raise_on_execute = raise_on_execute

    def cursor(self) -> _Cursor:
        return _Cursor(self)

    def close(self) -> None:
        self.closed = True


@pytest.fixture
def quiet(runner, monkeypatch: pytest.MonkeyPatch) -> io.StringIO:
    buffer = io.StringIO()
    monkeypatch.setattr(runner, "console", Console(file=buffer, width=120))
    return buffer


def _write_tests(directory: Path) -> None:
    (directory / "00_master_raw_tests.sql").write_text("CALL all_tests();")
    (directory / "01_schema.sql").write_text(
        "CREATE OR REPLACE PROCEDURE audit.dq_raw_schema() LANGUAGE plpgsql AS $$ BEGIN END; $$;"
    )
    (directory / "02_keys.sql").write_text("SELECT 1;")


class TestDiscover:
    def test_lists_numbered_tests_excluding_master(
        self, runner, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        _write_tests(tmp_path)
        monkeypatch.setattr(runner, "TEST_DIR", tmp_path)

        names = [p.name for p in runner.discover_tests(None)]

        assert names == ["01_schema.sql", "02_keys.sql"]

    def test_master_flag_lists_only_master(
        self, runner, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        _write_tests(tmp_path)
        monkeypatch.setattr(runner, "TEST_DIR", tmp_path)

        names = [p.name for p in runner.discover_tests(None, master=True)]

        assert names == ["00_master_raw_tests.sql"]

    def test_only_filters_by_substring(
        self, runner, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        _write_tests(tmp_path)
        monkeypatch.setattr(runner, "TEST_DIR", tmp_path)

        names = [p.name for p in runner.discover_tests("02")]

        assert names == ["02_keys.sql"]


class TestRunTest:
    def test_procedure_test_is_created_then_called_with_run_id(
        self, runner, tmp_path: Path
    ) -> None:
        path = tmp_path / "01_schema.sql"
        path.write_text(
            "CREATE OR REPLACE PROCEDURE audit.dq_raw_schema() LANGUAGE plpgsql AS $$ BEGIN END; $$;"
        )
        conn = _Conn(emit=["  checked 3 rows  ", ""])
        pipeline_run_id = uuid.uuid4()

        result = runner.run_test(conn, path, pipeline_run_id)

        assert result.passed and result.error is None
        assert result.notices == ["checked 3 rows"]
        assert result.name == "01_schema.sql"
        assert result.seconds >= 0
        assert len(conn.executed) == 2
        assert (
            "CALL audit.dq_raw_schema(p_pipeline_run_id => %s)" in conn.executed[1][0]
        )
        assert conn.executed[1][1] == (pipeline_run_id,)

    def test_plain_sql_test_runs_once(self, runner, tmp_path: Path) -> None:
        path = tmp_path / "02_keys.sql"
        path.write_text("SELECT 1;")
        conn = _Conn()

        result = runner.run_test(conn, path, None)

        assert result.passed
        assert conn.executed == [("SELECT 1;", None)]

    def test_failure_is_captured_not_raised(self, runner, tmp_path: Path) -> None:
        path = tmp_path / "03_fail.sql"
        path.write_text("SELECT broken;")
        conn = _Conn(emit=["boom"], raise_on_execute=True)

        result = runner.run_test(conn, path, None)

        assert result.passed is False
        assert result.error == "procedure failed: check violated"
        assert result.notices == ["boom"]


class TestRendering:
    def test_status_text_reflects_outcome(self, runner) -> None:
        passed = runner.TestResult(name="a", passed=True, seconds=0.1)
        failed = runner.TestResult(name="b", passed=False, seconds=0.2, error="x")

        assert runner._status_text(passed).plain == "PASS"
        assert runner._status_text(failed).plain == "FAIL"

    def test_summary_lists_every_result(self, runner, quiet: io.StringIO) -> None:
        results = [
            runner.TestResult(name="a.sql", passed=True, seconds=0.1),
            runner.TestResult(
                name="b.sql", passed=False, seconds=0.2, error="x", notices=["n1", "n2"]
            ),
        ]

        table = runner._build_summary(results)
        quiet_console = Console(file=quiet, width=120)
        quiet_console.print(table)
        text = quiet.getvalue()

        assert "a.sql" in text and "b.sql" in text
        assert "clean" in text and "2 notice(s)" in text

    def test_print_failures_skips_passing_tests(
        self, runner, quiet: io.StringIO
    ) -> None:
        results = [
            runner.TestResult(name="good.sql", passed=True, seconds=0.1),
            runner.TestResult(
                name="bad.sql", passed=False, seconds=0.2, error="violated"
            ),
        ]

        runner._print_failures(results)
        text = quiet.getvalue()

        assert "bad.sql" in text and "violated" in text
        assert "good.sql" not in text


class TestMain:
    def _point_at(
        self, runner, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> Path:
        tests = tmp_path / "tests"
        tests.mkdir()
        (tests / "01_ok.sql").write_text("SELECT 1;")
        monkeypatch.setattr(runner, "TEST_DIR", tests)
        return tests

    def test_no_tests_found_returns_one(
        self,
        runner,
        quiet: io.StringIO,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        monkeypatch.setattr(runner, "TEST_DIR", tmp_path)

        assert runner.main([]) == 1
        assert "No tests found" in quiet.getvalue()

    def test_list_mode_returns_zero(
        self,
        runner,
        quiet: io.StringIO,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        self._point_at(runner, monkeypatch, tmp_path)

        assert runner.main(["--list"]) == 0
        assert "01_ok.sql" in quiet.getvalue()

    def test_connection_failure_returns_two(
        self,
        runner,
        quiet: io.StringIO,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        self._point_at(runner, monkeypatch, tmp_path)

        def _boom(**kwargs):
            raise RuntimeError("cannot connect")

        monkeypatch.setattr(runner, "get_pg_connection", _boom)

        assert runner.main([]) == 2
        assert "Connection failed" in quiet.getvalue()

    def test_all_pass_returns_zero_and_closes_connection(
        self,
        runner,
        quiet: io.StringIO,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        self._point_at(runner, monkeypatch, tmp_path)
        conn = _Conn()
        monkeypatch.setattr(runner, "get_pg_connection", lambda **kw: conn)

        assert runner.main([]) == 0
        assert conn.autocommit is True
        assert conn.closed
        assert "All 1" in quiet.getvalue()

    def test_failure_returns_one(
        self,
        runner,
        quiet: io.StringIO,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        self._point_at(runner, monkeypatch, tmp_path)
        conn = _Conn(raise_on_execute=True)
        monkeypatch.setattr(runner, "get_pg_connection", lambda **kw: conn)

        assert runner.main([]) == 1
        assert "1 of 1 tests failed" in quiet.getvalue()

    def test_verbose_prints_notices(
        self,
        runner,
        quiet: io.StringIO,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        self._point_at(runner, monkeypatch, tmp_path)
        conn = _Conn(emit=["42 rows checked"])
        monkeypatch.setattr(runner, "get_pg_connection", lambda **kw: conn)

        assert runner.main(["-v"]) == 0
        assert "42 rows checked" in quiet.getvalue()

    def test_airflow_ids_start_pipeline_run(
        self,
        runner,
        quiet: io.StringIO,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        self._point_at(runner, monkeypatch, tmp_path)
        conn = _Conn()
        monkeypatch.setattr(runner, "get_pg_connection", lambda **kw: conn)
        import utils.audit as audit_mod

        seen: list[dict] = []
        monkeypatch.setattr(
            audit_mod,
            "start_pipeline_run",
            lambda **kw: seen.append(kw) or uuid.uuid4(),
        )

        assert runner.main(["--dag-id", "d", "--dag-run-id", "r"]) == 0
        assert seen == [{"dag_id": "d", "dag_run_id": "r", "trigger_type": "airflow"}]
