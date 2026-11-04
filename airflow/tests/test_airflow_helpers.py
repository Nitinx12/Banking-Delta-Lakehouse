"""Tests for the Airflow task callbacks, audit reader and finalizer."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "src"))

from banking_airflow import audit_reader, callbacks, finalize_audit  # noqa: E402


class _Cur:
    def __init__(self, conn: "_Conn") -> None:
        self.conn = conn

    def __enter__(self) -> "_Cur":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query: str, params: object = None) -> None:
        self.conn.calls.append((query, params))

    def fetchall(self) -> list[dict[str, object]]:
        return self.conn.rows


class _Conn:
    def __init__(self, rows: list[dict[str, object]] | None = None) -> None:
        self.rows = rows or []
        self.calls: list[tuple[str, object]] = []
        self.session: dict[str, object] | None = None
        self.closed = False

    def cursor(self, **kwargs: object) -> _Cur:
        return _Cur(self)

    def set_session(self, **kwargs: object) -> None:
        self.session = kwargs

    def close(self) -> None:
        self.closed = True


class TestAuditReader:
    def test_connect_is_read_only_and_autocommit(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        seen: dict[str, object] = {}
        conn = _Conn()

        def fake_connect(**kwargs: object) -> _Conn:
            seen.update(kwargs)
            return conn

        monkeypatch.setenv("PG_HOST", "db")
        monkeypatch.setenv("PG_DB", "warehouse")
        monkeypatch.setenv("PG_USER", "reporter")
        monkeypatch.delenv("PG_PASS", raising=False)
        monkeypatch.setattr("psycopg2.connect", fake_connect)

        assert audit_reader._connect() is conn
        assert seen["host"] == "db"
        assert seen["dbname"] == "warehouse"
        assert seen["password"] == ""
        assert seen["application_name"] == "banking-airflow-summary"
        assert conn.session == {"readonly": True, "autocommit": True}

    def test_query_returns_dicts_and_always_closes(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _Conn(rows=[{"n": 1}, {"n": 2}])
        monkeypatch.setattr(audit_reader, "_connect", lambda: conn)

        assert audit_reader._query("SELECT 1") == [{"n": 1}, {"n": 2}]
        assert conn.calls == [("SELECT 1", {})]
        assert conn.closed

    def test_query_closes_after_execute_error(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _Conn()

        def _boom(query: str, params: object = None) -> None:
            raise RuntimeError("bad sql")

        monkeypatch.setattr(conn, "cursor", lambda **kw: _BoomCur(_boom))
        monkeypatch.setattr(audit_reader, "_connect", lambda: conn)

        with pytest.raises(RuntimeError, match="bad sql"):
            audit_reader._query("SELECT broken")
        assert conn.closed

    def test_wrappers_scope_queries_to_the_dag_run(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        seen: list[tuple[str, dict[str, str] | None]] = []

        def fake_query(sql: str, params: dict[str, str] | None = None):
            seen.append((sql, params))
            return []

        monkeypatch.setattr(audit_reader, "_query", fake_query)

        assert audit_reader.table_runs("dag", "run") == []
        assert audit_reader.errors("dag", "run") == []
        assert audit_reader.dq_results("dag", "run") == []
        assert audit_reader.latest_dq() == []
        assert audit_reader.pipeline_run("dag", "run") is None

        params = {"dag_id": "dag", "dag_run_id": "run"}
        assert seen[0] == (audit_reader.TABLES_SQL, params)
        assert seen[1] == (audit_reader.ERRORS_SQL, params)
        assert seen[2] == (audit_reader.DQ_SQL, params)
        assert seen[3] == (audit_reader.LATEST_DQ_SQL, None)
        assert seen[4] == (audit_reader.RUN_SQL, params)

    def test_pipeline_run_returns_the_first_row(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            audit_reader, "_query", lambda sql, params=None: [{"status": "SUCCESS"}]
        )

        assert audit_reader.pipeline_run("d", "r") == {"status": "SUCCESS"}

    def test_task_states_keep_latest_attempt_and_skip_blank_ids(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        rows = [
            {"airflow_task_id": "extract", "status": "RUNNING"},
            {"airflow_task_id": "extract", "status": "SUCCESS"},
            {"airflow_task_id": None, "status": "SUCCESS"},
            {"airflow_task_id": "dq"},
        ]
        monkeypatch.setattr(audit_reader, "_query", lambda sql, params=None: rows)

        assert audit_reader.task_states("d", "r") == {
            "extract": "SUCCESS",
            "dq": "RUNNING",
        }


class _BoomCur(_Cur):
    def __init__(self, boom) -> None:
        self.boom = boom

    def __enter__(self) -> "_BoomCur":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query: str, params: object = None) -> None:
        self.boom(query, params)


class TestCallbacks:
    def test_disabled_by_env_flag(self, monkeypatch: pytest.MonkeyPatch) -> None:
        from banking_airflow import notify

        calls: list[object] = []
        monkeypatch.setattr(callbacks, "_ALERT_ON_TASK_FAILURE", False)
        monkeypatch.setattr(notify, "send_task_failure", lambda ctx: calls.append(ctx))

        callbacks.notify_task_failure({"task": "x"})

        assert calls == []

    def test_sends_once_when_enabled(self, monkeypatch: pytest.MonkeyPatch) -> None:
        from banking_airflow import notify

        calls: list[object] = []
        monkeypatch.setattr(callbacks, "_ALERT_ON_TASK_FAILURE", True)
        monkeypatch.setattr(notify, "send_task_failure", lambda ctx: calls.append(ctx))

        context = {"task": "x"}
        callbacks.notify_task_failure(context)

        assert calls == [context]

    def test_notification_errors_never_reach_airflow(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        from banking_airflow import notify

        def _boom(ctx: object) -> None:
            raise RuntimeError("smtp down")

        monkeypatch.setattr(callbacks, "_ALERT_ON_TASK_FAILURE", True)
        monkeypatch.setattr(notify, "send_task_failure", _boom)

        with caplog.at_level("ERROR"):
            callbacks.notify_task_failure({"task": "x"})

        assert any("notification failed" in r.message for r in caplog.records)


class TestFinalizeAudit:
    def test_without_airflow_context_is_a_noop(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.delenv("AIRFLOW_CTX_DAG_ID", raising=False)
        monkeypatch.delenv("AIRFLOW_CTX_DAG_RUN_ID", raising=False)
        monkeypatch.setattr(
            finalize_audit,
            "finalize_dag_run",
            lambda *a: pytest.fail("must not finalize without context"),
        )

        assert finalize_audit.main() == 0

    def test_finalizes_and_reports_missing_row(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        monkeypatch.setenv("AIRFLOW_CTX_DAG_ID", "dag")
        monkeypatch.setenv("AIRFLOW_CTX_DAG_RUN_ID", "run")
        seen: list[tuple[str, str]] = []
        monkeypatch.setattr(
            finalize_audit,
            "finalize_dag_run",
            lambda dag, run: seen.append((dag, run)),
        )

        with caplog.at_level("INFO"):
            assert finalize_audit.main() == 0

        assert seen == [("dag", "run")]
        assert any("No pipeline run recorded" in r.message for r in caplog.records)

    def test_finalizes_and_reports_status(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        monkeypatch.setenv("AIRFLOW_CTX_DAG_ID", "dag")
        monkeypatch.setenv("AIRFLOW_CTX_DAG_RUN_ID", "run")
        monkeypatch.setattr(finalize_audit, "finalize_dag_run", lambda *a: "SUCCESS")

        with caplog.at_level("INFO"):
            assert finalize_audit.main() == 0

        assert any("closed: SUCCESS" in r.message for r in caplog.records)
