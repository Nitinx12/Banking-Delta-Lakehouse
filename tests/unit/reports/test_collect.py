"""The collector is read-only, redacts secrets and degrades one section at a time."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any, Self

import pytest

from reports.scripts import collect

pytestmark = pytest.mark.unit

_NOW = datetime(2026, 10, 21, 2, tzinfo=UTC)
_HOUR = timedelta(hours=1)


class FakeCursor:
    def __init__(self, conn: FakeConn) -> None:
        self.conn = conn

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_args: object) -> bool:
        return False

    def execute(self, sql: str, params: tuple = ()) -> None:
        self.conn.calls.append((sql, params))
        self.conn.rows = self.conn.respond(sql)

    def fetchall(self) -> list[dict[str, Any]]:
        return [dict(row) for row in self.conn.rows]


class FakeConn:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple]] = []
        self.rows: list[dict[str, Any]] = []
        self.closed = False

    def cursor(self, **_kwargs: object) -> FakeCursor:
        return FakeCursor(self)

    def respond(self, sql: str) -> list[dict[str, Any]]:
        if "percentile_cont" in sql:
            return []
        if "SELECT status, total_tables" in sql:
            return [
                {
                    "status": "SUCCESS",
                    "total_tables": 1,
                    "successful_tables": 1,
                    "failed_tables": 0,
                    "skipped_tables": 0,
                    "started_at": _NOW,
                    "ended_at": _NOW + _HOUR,
                    "duration_seconds": 3600,
                }
            ]
        if "coalesce(sum(rows_landed)" in sql:
            return [{"rows_landed": 10, "failed_tables": 0}]
        if "SELECT pipeline_run_id" in sql:
            return [{"pipeline_run_id": 42}]
        if "GROUP BY airflow_task_id" in sql:
            return [
                {
                    "airflow_task_id": "extract_mongo",
                    "attempts": 2,
                    "started_at": _NOW,
                    "ended_at": _NOW + _HOUR,
                    "any_success": True,
                    "any_failed": False,
                }
            ]
        if "DISTINCT ON (processing_layer, target_table)" in sql:
            return [
                {
                    "processing_layer": "raw",
                    "target_table": "customers",
                    "attempt_number": 1,
                    "status": "SUCCESS",
                    "rows_extracted": 10,
                    "rows_landed": 10,
                    "watermark_start": None,
                    "watermark_end": None,
                }
            ]
        if "FROM audit.v_dq_latest" in sql:
            return [
                {
                    "layer": "raw",
                    "script_name": "01_lp_check_metadata_col.sql",
                    "status": "PASS",
                    "violation_count": 0,
                    "started_at": _NOW,
                }
            ]
        if "FROM audit.pipeline_errors" in sql:
            return [
                {
                    "error_category": "CONNECTION",
                    "severity": "CRITICAL",
                    "error_message": ("login failed password=hunter2 and " + "x" * 400),
                    "error_timestamp": _NOW,
                    "target_table": "customers",
                    "processing_layer": "raw",
                }
            ]
        if "FROM audit.source_tables" in sql:
            return []
        if "dag_run_id, status, duration_seconds" in sql and "dq_run" not in sql:
            return [
                {
                    "dag_run_id": "scheduled__2026-10-20T20:30:00+00:00",
                    "status": "SUCCESS",
                    "duration_seconds": 3600,
                    "ended_at": _NOW + _HOUR,
                }
            ]
        if "FROM audit.dq_run" in sql:
            return [{"n": 0}]
        if (
            "FROM audit.pipeline_runs" in sql
            and "dq_run" not in sql
            and "ended_at" not in sql
        ):
            return []
        return []


def test_collect_is_read_only_and_redacts() -> None:
    conn = FakeConn()
    context = collect.collect(kind="daily", dag_id="d", dag_run_id="r", conn=conn)
    assert context["schema_version"] == 2
    assert context["run"]["status"] == "SUCCESS"
    assert context["sections_failed"] == []
    assert context["errors"][0]["message"].startswith("login failed password=***")
    assert len(context["errors"][0]["message"]) <= 300
    assert context["steps"][1]["name"] == "extract_mongo"
    assert context["steps"][1]["state"] == "ok"
    assert context["steps"][1]["duration_s"] == 3600.0
    assert context["steps"][1]["evidence"] is True
    assert context["steps"][1]["start_offset_s"] == 0.0
    assert context["steps"][1]["end_offset_s"] == 3600.0
    assert context["steps"][0]["evidence"] is False
    assert context["steps"][0]["start_offset_s"] is None
    assert context["tables"][0]["label"] == "raw.customers"
    assert context["tables"][0]["median_rows"] is None
    assert context["trends"][0]["rows_landed"] == 10
    assert any("processing_layer = 'raw'" in sql for sql, _ in conn.calls)
    assert any("percentile_cont" in sql for sql, _ in conn.calls)
    assert all("INSERT" not in sql.upper() for sql, _ in conn.calls)
    assert all("UPDATE" not in sql.upper() for sql, _ in conn.calls)
    assert all("DELETE" not in sql.upper() for sql, _ in conn.calls)


def test_one_broken_section_degrades_only_itself() -> None:
    class Broken(FakeConn):
        def respond(self, sql: str) -> list[dict[str, Any]]:
            if "FROM audit.v_dq_latest" in sql:
                raise RuntimeError("boom")
            if "dag_run_id, status, duration_seconds" in sql and "dq_run" not in sql:
                return []
            if "coalesce(sum(rows_landed)" in sql:
                return [{"rows_landed": 10, "failed_tables": 0}]
            if "FROM audit.dq_run" in sql:
                return [{"n": 0}]
            return super().respond(sql)

    context = collect.collect(kind="daily", dag_id="d", dag_run_id="r", conn=Broken())
    assert context["sections_failed"] == ["dq"]
    assert context["dq"] == []
    assert context["run"]["status"] == "SUCCESS"


def test_connect_requests_a_read_only_session(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: dict[str, Any] = {}

    class Driver:
        def set_session(self, **kwargs: object) -> None:
            seen["session"] = kwargs

    def fake_connect(**kwargs: object) -> Driver:
        seen["connect"] = kwargs
        return Driver()

    monkeypatch.setattr("psycopg2.connect", fake_connect)
    collect._connect()
    assert "default_transaction_read_only=on" in str(seen["connect"]["options"])
    assert seen["session"]["readonly"] is True
    assert seen["session"]["autocommit"] is True


def test_window_seconds_parses_iso_windows() -> None:
    from reports.scripts.collect import _window_seconds

    assert _window_seconds("PT24H") == 86400.0
    assert _window_seconds("P1DT2H") == 93600.0
    assert _window_seconds("nonsense") == 0.0


def test_freshness_uses_watermarks_and_degrades_to_loaded_at(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    now = datetime.now(UTC)
    registry = [
        {
            "target_table": "branches",
            "load_strategy": "full",
            "source_id": "mysql_source",
        },
        {
            "target_table": "events",
            "load_strategy": "incremental",
            "source_id": "mongo_source",
        },
        {
            "target_table": "cards",
            "load_strategy": "full",
            "source_id": "databricks_source",
        },
        {
            "target_table": "logs",
            "load_strategy": "incremental",
            "source_id": "mysql_source",
        },
        {
            "target_table": "orders",
            "load_strategy": "incremental",
            "source_id": "mysql_source",
        },
    ]
    watermarks = {
        "events": (now - timedelta(hours=30)).isoformat(),
        "logs": None,
        "orders": "not-a-timestamp",
    }
    loaded = iter([now - timedelta(hours=1), None, now - timedelta(minutes=5), None])
    calls: list[tuple[str, tuple]] = []

    def fake_fetch(conn: object, query: str, params: tuple = ()):
        calls.append((query, params))
        if "load_strategy" in query:
            return registry
        if "extract_watermarks" in query:
            return [{"last_watermark_value": watermarks[params[0]]}]
        if "max(_loaded_at)" in query:
            return [{"loaded": next(loaded)}]
        if "SELECT status, total_tables" in query:
            return [
                {
                    "status": "SUCCESS",
                    "total_tables": 5,
                    "successful_tables": 5,
                    "failed_tables": 0,
                    "skipped_tables": 0,
                    "started_at": now,
                    "ended_at": now,
                    "duration_seconds": 0,
                }
            ]
        return []

    from psycopg2 import sql

    monkeypatch.setattr(
        sql.Composable,
        "as_string",
        lambda self, context=None: "SELECT max(_loaded_at)",
    )
    monkeypatch.setattr(
        sql.Identifier,
        "as_string",
        lambda self, context=None: "SELECT max(_loaded_at)",
    )
    monkeypatch.setattr(collect, "_fetch", fake_fetch)
    monkeypatch.setattr(
        collect.paths,
        "load_report_config",
        lambda: {"thresholds": {"freshness_default_window": "PT24H"}},
    )
    monkeypatch.setattr(
        collect.paths,
        "load_slo_config",
        lambda: {"tables": {"events": {"window": "PT24H", "severity": "CRITICAL"}}},
    )

    context = collect.collect(kind="daily", dag_id="d", dag_run_id="r", conn=object())

    assert context["sections_failed"] == []
    rows = {row["table"]: row for row in context["freshness"]}

    assert rows["branches"]["window"] == "N/A (full reload)"
    assert rows["branches"]["breached"] is False
    assert rows["branches"]["severity"] == "INFO"
    assert 3000 < rows["branches"]["age_s"] < 4200

    assert rows["cards"]["age_s"] is None
    assert rows["cards"]["breached"] is False

    assert rows["events"]["window"] == "PT24H"
    assert rows["events"]["severity"] == "CRITICAL"
    assert rows["events"]["breached"] is True

    assert rows["logs"]["breached"] is False
    assert 0 <= rows["logs"]["age_s"] < 900

    assert rows["orders"]["age_s"] is None
    assert rows["orders"]["breached"] is False
