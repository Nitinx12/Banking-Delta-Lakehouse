"""Unit tests for src/utils/audit.py — redaction, classification, run tracking, watermarks."""

from __future__ import annotations

import uuid
from contextlib import contextmanager

import psycopg2
import pytest

from src.utils import audit
from src.utils.audit import WatermarkConflict

pytestmark = pytest.mark.unit


class _FakeCursor:
    """Cursor that records SQL and serves canned rows."""

    def __init__(self, conn: "_FakeConn") -> None:
        self.conn = conn
        self.rowcount = 0
        self._rows: list = []

    def __enter__(self) -> "_FakeCursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query: str, params: tuple | None = None) -> None:
        self.conn.executed.append((query, params))
        rows = self.conn.next_rows
        self._rows = list(rows() if callable(rows) else rows)
        self.rowcount = self.conn.next_rowcount

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def fetchall(self):
        return self._rows


class _FakeConn:
    """Connection stand-in: canned rows per execute, records every statement."""

    def __init__(self, rows: list | None = None, rowcount: int = 1) -> None:
        self.executed: list[tuple[str, tuple | None]] = []
        self.next_rows: list = rows or []
        self.next_rowcount = rowcount

    def cursor(self, cursor_factory=None) -> _FakeCursor:
        return _FakeCursor(self)


@pytest.fixture
def conn() -> _FakeConn:
    return _FakeConn()


@pytest.fixture
def own_transaction(monkeypatch: pytest.MonkeyPatch) -> _FakeConn:
    """Replace audit.pg_transaction so conn=None paths use a fake connection."""
    fake = _FakeConn()

    @contextmanager
    def _tx():
        yield fake

    monkeypatch.setattr(audit, "pg_transaction", _tx)
    return fake


class TestRedact:
    def test_password_query_param_is_masked(self) -> None:
        assert (
            audit._redact("connect password=hunter2 now") == "connect password=*** now"
        )

    def test_url_credentials_are_masked(self) -> None:
        out = audit._redact("postgres://alice:s3cret@host/db")
        assert out == "postgres://alice:***@host/db"
        assert "s3cret" not in out

    def test_plain_text_is_untouched(self) -> None:
        assert audit._redact("relation does not exist") == "relation does not exist"


class TestClassify:
    def test_watermark_conflict_is_concurrency(self) -> None:
        assert audit._classify(WatermarkConflict("x")) == ("CONCURRENCY", False)

    @pytest.mark.parametrize(
        ("exc", "category"),
        [
            (psycopg2.OperationalError("down"), "CONNECTION"),
            (TimeoutError("slow"), "CONNECTION"),
            (psycopg2.IntegrityError("dup"), "DATA"),
            (psycopg2.ProgrammingError("typo"), "DATA"),
            (ValueError("bad"), "UNKNOWN"),
        ],
    )
    def test_exception_categories(self, exc: BaseException, category: str) -> None:
        assert audit._classify(exc)[0] == category

    def test_spark_style_error_is_spark_category(self) -> None:
        class Py4JJavaError(Exception):
            pass

        assert audit._classify(Py4JJavaError("jvm")) == ("SPARK", False)

    def test_connection_errors_are_recoverable(self) -> None:
        assert audit._classify(psycopg2.OperationalError("down"))[1] is True


class TestPipelineRuns:
    def test_start_pipeline_run_returns_id_from_row(self, conn: _FakeConn) -> None:
        run_id = uuid.uuid4()
        conn.next_rows = [{"pipeline_run_id": run_id}]

        assert audit.start_pipeline_run(dag_id="d", dag_run_id="r", conn=conn) == run_id
        query, params = conn.executed[0]
        assert "ON CONFLICT (dag_id, dag_run_id)" in query
        assert params[1] == "d"

    def test_start_pipeline_run_opens_own_transaction_without_conn(
        self, own_transaction: _FakeConn
    ) -> None:
        own_transaction.next_rows = [{"pipeline_run_id": uuid.uuid4()}]

        result = audit.start_pipeline_run(dag_id="d")

        assert isinstance(result, uuid.UUID)
        assert own_transaction.executed

    def test_finish_pipeline_run_returns_status(self, conn: _FakeConn) -> None:
        conn.next_rows = [{"status": "PARTIAL"}]

        assert audit.finish_pipeline_run(uuid.uuid4(), conn=conn) == "PARTIAL"
        assert "DISTINCT ON" in conn.executed[0][0]

    def test_finalize_dag_run_returns_none_when_never_recorded(
        self, conn: _FakeConn
    ) -> None:
        conn.next_rows = []

        assert audit.finalize_dag_run("d", "r", conn=conn) is None

    def test_finalize_dag_run_reaps_running_then_rolls_up(
        self, conn: _FakeConn
    ) -> None:
        # first _q: pipeline_run_id; second: reaped count; third: status
        conn.next_rows = [{"pipeline_run_id": uuid.uuid4()}]

        class _SequencingCursor(_FakeCursor):
            def execute(self, query: str, params=None) -> None:
                if "UPDATE audit.table_runs" in query:
                    self.conn.next_rowcount = 1
                elif "UPDATE audit.pipeline_runs" in query:
                    self.conn.next_rows = [{"status": "FAILED"}]
                super().execute(query, params)

        conn.cursor = lambda cursor_factory=None: _SequencingCursor(conn)  # type: ignore[method-assign]

        assert audit.finalize_dag_run("d", "r", conn=conn) == "FAILED"
        assert any("task_never_finished" in q for q, _ in conn.executed)


class TestTableRuns:
    def test_get_enabled_tables_returns_rows(self, conn: _FakeConn) -> None:
        conn.next_rows = [{"config_id": 1}]

        assert audit.get_enabled_tables("mysql_source", conn=conn) == [{"config_id": 1}]
        assert "is_enabled" in conn.executed[0][0]

    def test_start_table_run_returns_uuid_and_bumps_attempt(
        self, conn: _FakeConn
    ) -> None:
        cfg = {
            "config_id": 7,
            "source_id": 3,
            "source_schema": "db",
            "source_table": "t",
            "target_schema": "raw",
            "target_table": "t",
            "load_strategy": "full",
        }

        result = audit.start_table_run(uuid.uuid4(), cfg, conn=conn)

        assert isinstance(result, uuid.UUID)
        query, params = conn.executed[0]
        assert "MAX(attempt_number)" in query
        assert params[4] == "db.t" and params[5] == "raw.t"
        assert params[7] == "full"

    def test_finish_table_run_rejects_unknown_status(self, conn: _FakeConn) -> None:
        with pytest.raises(ValueError, match="Invalid final status"):
            audit.finish_table_run(uuid.uuid4(), "RETRYING", conn=conn)

    def test_finish_table_run_passes_counts_and_metadata(self, conn: _FakeConn) -> None:
        audit.finish_table_run(
            uuid.uuid4(),
            "SUCCESS",
            rows_extracted=10,
            rows_landed=9,
            watermark_start="a",
            watermark_end="b",
            metadata={"k": "v"},
            conn=conn,
        )

        query, params = conn.executed[0]
        assert "UPDATE audit.table_runs" in query
        assert params[0] == "SUCCESS"
        assert params[1] == 10 and params[2] == 9
        assert params[3] == "a" and params[4] == "b"

    def test_log_error_without_table_run_skips_attempt_lookup(
        self, conn: _FakeConn
    ) -> None:
        conn.next_rows = [{"error_id": 42}]

        error_id = audit.log_error(RuntimeError("boom password=topsecret"), conn=conn)

        assert error_id == 42
        # insert + no attempt lookup + no table_runs link
        assert len(conn.executed) == 1
        assert "topsecret" not in str(conn.executed[0][1])

    def test_log_error_links_table_run_and_redacts(self, conn: _FakeConn) -> None:
        responses = iter([[{"attempt_number": 2}], [{"error_id": 9}], []])
        conn.next_rows = lambda: next(responses)

        error_id = audit.log_error(
            RuntimeError("token=abc123"),
            pipeline_run_id=uuid.uuid4(),
            table_run_id=uuid.uuid4(),
            conn=conn,
        )

        assert error_id == 9
        assert len(conn.executed) == 3  # attempt lookup, insert, link update
        insert_params = conn.executed[1][1]
        assert "abc123" not in str(insert_params)

    def test_table_run_success_persists_fields(self) -> None:
        finished: list[tuple] = []
        started = {"id": uuid.uuid4()}

        def _start(*args, **kwargs):
            return started["id"]

        def _finish(table_run_id, status, **kwargs):
            finished.append((table_run_id, status, kwargs))

        import src.utils.audit as mod

        original = (mod.start_table_run, mod.finish_table_run)
        mod.start_table_run = _start  # type: ignore[assignment]
        mod.finish_table_run = _finish  # type: ignore[assignment]
        try:
            with mod.table_run(
                uuid.uuid4(), {"source_schema": "s", "source_table": "t"}
            ) as run:
                run.rows_extracted = 5
                run.rows_landed = 5
        finally:
            mod.start_table_run, mod.finish_table_run = original  # type: ignore[assignment]

        assert finished[0][1] == "SUCCESS"
        assert finished[0][2]["rows_extracted"] == 5

    def test_table_run_skip_marks_skipped(self) -> None:
        finished: list[tuple] = []

        import src.utils.audit as mod

        original = (mod.start_table_run, mod.finish_table_run)
        mod.start_table_run = lambda *a, **k: uuid.uuid4()  # type: ignore[assignment]
        mod.finish_table_run = lambda tid, status, **k: finished.append(  # type: ignore[assignment]
            (status, k.get("metadata"))
        )
        try:
            with mod.table_run(
                uuid.uuid4(), {"source_schema": "s", "source_table": "t"}
            ) as run:
                run.skip("no new data")
        finally:
            mod.start_table_run, mod.finish_table_run = original  # type: ignore[assignment]

        assert finished[0][0] == "SKIPPED"
        assert finished[0][1]["skip_reason"] == "no new data"

    def test_table_run_failure_logs_and_reraises(self) -> None:
        errors: list[BaseException] = []
        finished: list[str] = []

        import src.utils.audit as mod

        original = (
            mod.start_table_run,
            mod.finish_table_run,
            mod.log_error,
        )
        mod.start_table_run = lambda *a, **k: uuid.uuid4()  # type: ignore[assignment]
        mod.finish_table_run = lambda tid, status, **k: finished.append(status)  # type: ignore[assignment]
        mod.log_error = lambda exc, **k: errors.append(exc) or 1  # type: ignore[assignment]
        try:
            with pytest.raises(RuntimeError, match="load exploded"):
                with mod.table_run(
                    uuid.uuid4(), {"source_schema": "s", "source_table": "t"}
                ):
                    raise RuntimeError("load exploded")
        finally:
            mod.start_table_run, mod.finish_table_run, mod.log_error = original  # type: ignore[assignment]

        assert errors and str(errors[0]) == "load exploded"
        assert finished == ["FAILED"]

    def test_table_run_survives_audit_failure_during_error_handling(self) -> None:
        """A broken audit write must not hide the original error."""
        import src.utils.audit as mod

        original = (mod.start_table_run, mod.finish_table_run, mod.log_error)
        mod.start_table_run = lambda *a, **k: uuid.uuid4()  # type: ignore[assignment]
        mod.log_error = lambda *a, **k: (_ for _ in ()).throw(
            RuntimeError("audit down")
        )  # type: ignore[assignment]
        mod.finish_table_run = lambda *a, **k: None  # type: ignore[assignment]
        try:
            with pytest.raises(ValueError, match="real failure"):
                with mod.table_run(
                    uuid.uuid4(), {"source_schema": "s", "source_table": "t"}
                ):
                    raise ValueError("real failure")
        finally:
            mod.start_table_run, mod.finish_table_run, mod.log_error = original  # type: ignore[assignment]


class TestWatermarks:
    def test_get_watermark_selects_by_config(self, conn: _FakeConn) -> None:
        conn.next_rows = [{"config_id": 1, "last_watermark_value": "x"}]

        assert audit.get_watermark(1, conn=conn)["last_watermark_value"] == "x"
        assert "audit.extract_watermarks" in conn.executed[0][0]

    def test_begin_batch_does_not_advance_lock_version(self, conn: _FakeConn) -> None:
        conn.next_rows = [{"lock_version": 3, "last_watermark_value": "old"}]
        cfg = {
            "source_id": 1,
            "config_id": 2,
            "incremental_column": "created_at",
            "watermark_strategy": "timestamp",
        }

        out = audit.begin_batch(cfg, "a", "b", conn=conn)

        assert out["lock_version"] == 3
        query = conn.executed[0][0]
        assert "RETURNING lock_version" in query
        assert "lock_version + 1" not in query

    def test_advance_watermark_raises_on_lost_lock(self, conn: _FakeConn) -> None:
        conn.next_rowcount = 0

        with pytest.raises(WatermarkConflict, match="expected lock_version=4"):
            audit.advance_watermark(
                1,
                "2024-01-01",
                expected_lock_version=4,
                table_run_id=uuid.uuid4(),
                pipeline_run_id=uuid.uuid4(),
                conn=conn,
            )

    def test_advance_watermark_updates_when_lock_matches(self, conn: _FakeConn) -> None:
        conn.next_rowcount = 1

        audit.advance_watermark(
            1,
            "2024-01-01",
            expected_lock_version=4,
            table_run_id=uuid.uuid4(),
            pipeline_run_id=uuid.uuid4(),
            conn=conn,
        )

        query, params = conn.executed[0]
        assert "lock_version + 1" in query
        assert params[0] == "2024-01-01"
        assert params[3] == 1 and params[4] == 4

    def test_seed_watermark_returns_false_when_unchanged(self, conn: _FakeConn) -> None:
        conn.next_rows = []

        cfg = {
            "source_id": 1,
            "config_id": 2,
            "incremental_column": "_id",
            "watermark_strategy": "objectid",
        }
        assert audit.seed_watermark(cfg, "64b000000000000000000000", conn=conn) is False

    def test_seed_watermark_returns_true_when_seeded(self, conn: _FakeConn) -> None:
        conn.next_rows = [{"config_id": 2}]
        cfg = {
            "source_id": 1,
            "config_id": 2,
            "incremental_column": "_id",
            "watermark_strategy": "objectid",
        }

        assert (
            audit.seed_watermark(cfg, "64b000000000000000000000", force=True, conn=conn)
            is True
        )
        assert (
            "WHERE audit.extract_watermarks.last_watermark_value IS NULL"
            in conn.executed[0][0]
        )


class TestDataQualityAndHygiene:
    def test_log_dq_result_rejects_bad_status(self, conn: _FakeConn) -> None:
        with pytest.raises(ValueError, match="PASSED"):
            audit.log_dq_result(check_name="c", status="MAYBE", conn=conn)

    @pytest.mark.parametrize("status", ["passed", "FAILED", "warning"])
    def test_log_dq_result_uppercases_status(
        self, conn: _FakeConn, status: str
    ) -> None:
        audit.log_dq_result(check_name="c", status=status, conn=conn)
        assert conn.executed[0][1][4] == status.upper()

    def test_fail_stale_runs_reaps_table_and_pipeline_rows(
        self, conn: _FakeConn
    ) -> None:
        conn.next_rowcount = 3

        reaped = audit.fail_stale_runs(max_age_hours=6, conn=conn)

        assert reaped == 3
        assert len(conn.executed) == 2
        assert "stale_reaped" in conn.executed[0][0]
        assert "make_interval(hours => %s)" in conn.executed[0][0]

    def test_fail_stale_runs_returns_zero_when_nothing_stale(
        self, conn: _FakeConn
    ) -> None:
        conn.next_rowcount = 0

        assert audit.fail_stale_runs(conn=conn) == 0
