"""Unit tests for the Airflow preflight checks."""

from __future__ import annotations

import smtplib
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import pytest

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT / "src") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "src"))

from banking_airflow import preflight  # noqa: E402 - sys.path set above


class _Cursor:
    def __init__(self, row=("audit.pipeline_runs",)) -> None:
        self.row = row
        self.calls: list[str] = []

    def __enter__(self) -> "_Cursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query: str) -> None:
        self.calls.append(query)

    def fetchone(self):
        return self.row

    def fetchall(self):
        return []


class _Conn:
    def __init__(self, row=("audit.pipeline_runs",)) -> None:
        self.cur = _Cursor(row)
        self.closed = False

    def __enter__(self) -> "_Conn":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def cursor(self) -> _Cursor:
        return self.cur

    def close(self) -> None:
        self.closed = True


class TestJava:
    def test_missing_java_raises(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(preflight.shutil, "which", lambda name: None)

        with pytest.raises(RuntimeError, match="java not found"):
            preflight._check_java()

    def test_supported_java_is_logged(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(preflight.shutil, "which", lambda name: "java")
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **k: SimpleNamespace(stderr='openjdk version "17.0.2" 2022'),
        )

        preflight._check_java()

    def test_unsupported_java_raises(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(preflight.shutil, "which", lambda name: "java")
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **k: SimpleNamespace(stderr='java version "1.6.0"'),
        )

        with pytest.raises(RuntimeError, match="not supported"):
            preflight._check_java()

    def test_unparseable_version_raises(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(preflight.shutil, "which", lambda name: "java")
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **k: SimpleNamespace(stderr="no version tokens"),
        )

        with pytest.raises(RuntimeError, match="could not parse"):
            preflight._check_java()


class TestDisk:
    def test_enough_space_passes(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(
            preflight.shutil,
            "disk_usage",
            lambda root: SimpleNamespace(free=preflight.MIN_FREE_BYTES + 1),
        )

        preflight._check_disk()

    def test_low_space_raises(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(
            preflight.shutil,
            "disk_usage",
            lambda root: SimpleNamespace(free=preflight.MIN_FREE_BYTES - 1),
        )

        with pytest.raises(RuntimeError, match="need >= 5 GB"):
            preflight._check_disk()


class TestConnectivity:
    def test_warehouse_ok(self, monkeypatch: pytest.MonkeyPatch) -> None:
        conn = _Conn()
        monkeypatch.setattr(preflight, "get_pg_connection", lambda name: conn)

        preflight._check_warehouse()

        assert conn.cur.calls == [
            "SELECT 1",
            "SELECT to_regclass('audit.pipeline_runs')",
        ]

    def test_warehouse_missing_audit_table_raises(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            preflight, "get_pg_connection", lambda name: _Conn(row=(None,))
        )

        with pytest.raises(RuntimeError, match="audit.pipeline_runs is missing"):
            preflight._check_warehouse()

    def test_mysql_closes_connection(self, monkeypatch: pytest.MonkeyPatch) -> None:
        conn = _Conn()
        monkeypatch.setattr(preflight, "get_mysql_connection", lambda: conn)

        preflight._check_mysql()

        assert conn.closed
        assert conn.cur.calls == ["SELECT 1"]

    def test_mongo_pings_and_closes(self, monkeypatch: pytest.MonkeyPatch) -> None:
        class _Client:
            def __init__(self) -> None:
                self.admin = SimpleNamespace(command=lambda name: {"ok": 1})
                self.closed = False

            def close(self) -> None:
                self.closed = True

        client = _Client()
        monkeypatch.setattr(preflight, "get_mongo_client", lambda: client)

        preflight._check_mongo()

        assert client.closed

    def test_databricks_selects_and_closes(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _Conn()
        monkeypatch.setattr(preflight, "get_databricks_connection", lambda: conn)

        preflight._check_databricks()

        assert conn.closed
        assert conn.cur.calls == ["SELECT 1"]

    def test_maven_connects(self, monkeypatch: pytest.MonkeyPatch) -> None:
        seen: list[tuple] = []

        @contextmanager
        def _connect(address, timeout):
            seen.append((address, timeout))
            yield None

        monkeypatch.setattr(preflight.socket, "create_connection", _connect)

        preflight._check_maven()

        assert seen == [(("repo1.maven.org", 443), 10)]


class TestSmtp:
    def test_missing_host_is_only_a_warning(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        monkeypatch.delenv("SMTP_HOST", raising=False)

        with caplog.at_level("WARNING"):
            preflight._check_smtp()

        assert any("SMTP_HOST not set" in r.message for r in caplog.records)

    def test_reachable_smtp(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("SMTP_HOST", "mail.example")
        monkeypatch.delenv("SMTP_PORT", raising=False)
        greeted: list[bool] = []

        class _Smtp:
            def __init__(self, host, port, timeout) -> None:
                assert (host, port, timeout) == ("mail.example", 587, 10)

            def __enter__(self) -> "_Smtp":
                return self

            def __exit__(self, *exc: object) -> None:
                return None

            def ehlo(self) -> None:
                greeted.append(True)

        monkeypatch.setattr(smtplib, "SMTP", _Smtp)

        preflight._check_smtp()

        assert greeted == [True]

    def test_unreachable_smtp_is_only_a_warning(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        monkeypatch.setenv("SMTP_HOST", "mail.example")

        class _Smtp:
            def __init__(self, host, port, timeout) -> None:
                raise OSError("connection refused")

        monkeypatch.setattr(smtplib, "SMTP", _Smtp)

        with caplog.at_level("WARNING"):
            preflight._check_smtp()

        assert any("SMTP not reachable" in r.message for r in caplog.records)


class TestMain:
    def test_all_checks_pass(self, monkeypatch: pytest.MonkeyPatch) -> None:
        called: list[str] = []
        for name in (
            "_check_java",
            "_check_disk",
            "_check_warehouse",
            "_check_mysql",
            "_check_mongo",
            "_check_databricks",
            "_check_maven",
        ):
            monkeypatch.setattr(preflight, name, lambda n=name: called.append(n))
        smtp: list[bool] = []
        monkeypatch.setattr(preflight, "_check_smtp", lambda: smtp.append(True))

        assert preflight.main() == 0
        assert called == [
            "_check_java",
            "_check_disk",
            "_check_warehouse",
            "_check_mysql",
            "_check_mongo",
            "_check_databricks",
            "_check_maven",
        ]
        assert smtp == [True]

    def test_first_failure_stops_remaining_checks(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        called: list[str] = []

        def _fail() -> None:
            called.append("java")
            raise RuntimeError("boom")

        monkeypatch.setattr(preflight, "_check_java", _fail)
        monkeypatch.setattr(preflight, "_check_disk", lambda: called.append("disk"))
        smtp: list[bool] = []
        monkeypatch.setattr(preflight, "_check_smtp", lambda: smtp.append(True))

        assert preflight.main() == 1
        assert called == ["java"]
        assert smtp == []
