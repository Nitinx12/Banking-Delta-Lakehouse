"""Transient Databricks failures are retried with backoff; real errors are not."""

from __future__ import annotations

import pytest

from src.utils import connection
from src.utils.connection import databricks_transient, dbx_call

pytestmark = pytest.mark.unit

_CAPACITY = "Error during request to server: BAD_REQUEST: Cannot create the resource, please try again later."


class _FakeTime:
    """Records requested sleeps instead of waiting."""

    def __init__(self) -> None:
        self.sleeps: list[float] = []

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)


@pytest.fixture
def clock(monkeypatch: pytest.MonkeyPatch) -> _FakeTime:
    fake = _FakeTime()
    monkeypatch.setattr(connection, "time", fake)
    return fake


def test_transient_error_is_retried_until_it_succeeds(clock: _FakeTime) -> None:
    attempts = 0

    def flaky() -> str:
        nonlocal attempts
        attempts += 1
        if attempts < 3:
            raise RuntimeError(_CAPACITY)
        return "rows"

    assert dbx_call("public.loans", flaky) == "rows"
    assert attempts == 3
    assert clock.sleeps == [5.0, 10.0], "exponential backoff between attempts"


def test_non_transient_error_fails_immediately(clock: _FakeTime) -> None:
    attempts = 0

    def broken() -> None:
        nonlocal attempts
        attempts += 1
        raise ValueError("Unsafe or empty Databricks identifier: '; drop")

    with pytest.raises(ValueError):
        dbx_call("public.loans", broken)
    assert attempts == 1
    assert clock.sleeps == []


def test_transient_error_gives_up_after_the_attempt_budget(
    clock: _FakeTime, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("DATABRICKS_MAX_ATTEMPTS", "2")
    monkeypatch.setenv("DATABRICKS_RETRY_BASE_SECONDS", "1")
    attempts = 0

    def always_down() -> None:
        nonlocal attempts
        attempts += 1
        raise RuntimeError(_CAPACITY)

    with pytest.raises(RuntimeError):
        dbx_call("public.loans", always_down)
    assert attempts == 2
    assert clock.sleeps == [1.0]


def test_retry_budget_is_capped(
    clock: _FakeTime, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("DATABRICKS_MAX_ATTEMPTS", "4")
    monkeypatch.setenv("DATABRICKS_RETRY_BASE_SECONDS", "30")

    def always_down() -> None:
        raise RuntimeError(_CAPACITY)

    with pytest.raises(RuntimeError):
        dbx_call("public.loans", always_down)
    assert clock.sleeps == [30.0, 60.0, 60.0], "backoff never exceeds 60s"


def test_connection_failures_count_as_transient() -> None:
    assert databricks_transient(ConnectionResetError("reset"))
    assert databricks_transient(TimeoutError("timed out"))
    assert databricks_transient(RuntimeError("RESOURCE_EXHAUSTED"))
    assert not databricks_transient(ValueError("Bad timestamp watermark"))


class TestGetters:
    def test_pg_connection_sets_utc_and_lock_timeout(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        seen: dict[str, object] = {}
        monkeypatch.setenv("PG_HOST", "db")
        monkeypatch.setenv("PG_DB", "warehouse")
        monkeypatch.setenv("PG_USER", "loader")
        monkeypatch.setenv("PG_LOCK_TIMEOUT", "30s")
        monkeypatch.setattr("psycopg2.connect", lambda **kw: seen.update(kw) or "conn")

        assert connection.get_pg_connection("unit") == "conn"
        assert seen["application_name"] == "unit"
        assert "-c timezone=UTC" in str(seen["options"])
        assert "lock_timeout=30s" in str(seen["options"])

    def test_pg_connection_requires_host(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("PG_HOST", raising=False)

        with pytest.raises(RuntimeError, match="PG_HOST"):
            connection.get_pg_connection()

    def test_mysql_connection_forces_utc(self, monkeypatch: pytest.MonkeyPatch) -> None:
        executed: list[str] = []

        class _Cur:
            def __enter__(self):
                return self

            def __exit__(self, *exc: object) -> None:
                return None

            def execute(self, query: str) -> None:
                executed.append(query)

        class _Conn:
            def cursor(self) -> _Cur:
                return _Cur()

        seen: dict[str, object] = {}
        monkeypatch.setenv("MYSQL_HOST", "db")
        monkeypatch.setenv("MYSQL_USER", "reader")
        monkeypatch.setenv("MYSQL_DB", "source")
        monkeypatch.setattr("pymysql.connect", lambda **kw: seen.update(kw) or _Conn())

        connection.get_mysql_connection()

        assert seen["autocommit"] is True
        assert seen["charset"] == "utf8mb4"
        assert executed == ["SET time_zone = '+00:00'"]

    def test_mongo_client_uses_uri(self, monkeypatch: pytest.MonkeyPatch) -> None:
        seen: dict[str, object] = {}
        monkeypatch.setenv("MONGO_URI", "mongodb://db")
        monkeypatch.setattr(
            "pymongo.MongoClient",
            lambda uri, **kw: seen.update(uri=uri, **kw) or "client",
        )

        assert connection.get_mongo_client() == "client"
        assert seen["uri"] == "mongodb://db"
        assert seen["appname"] == "banking-pipeline"

    def test_databricks_connection_includes_optional_schema(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        seen: dict[str, object] = {}
        monkeypatch.setenv("DATABRICKS_HOST", "host")
        monkeypatch.setenv("DATABRICKS_HTTP_PATH", "/sql")
        monkeypatch.setenv("DATABRICKS_TOKEN", "token")
        monkeypatch.setenv("DATABRICKS_SCHEMA", "core")
        monkeypatch.setenv("DATABRICKS_CATALOG", "main")
        monkeypatch.setattr(
            "databricks.sql.connect", lambda **kw: seen.update(kw) or "conn"
        )

        assert connection.get_databricks_connection() == "conn"
        assert seen["schema"] == "core"
        assert seen["catalog"] == "main"

    def test_databricks_connection_omits_blank_schema(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        seen: dict[str, object] = {}
        monkeypatch.setenv("DATABRICKS_HOST", "host")
        monkeypatch.setenv("DATABRICKS_HTTP_PATH", "/sql")
        monkeypatch.setenv("DATABRICKS_TOKEN", "token")
        monkeypatch.delenv("DATABRICKS_SCHEMA", raising=False)
        monkeypatch.setenv("DATABRICKS_CATALOG", "main")
        monkeypatch.setattr(
            "databricks.sql.connect", lambda **kw: seen.update(kw) or "conn"
        )

        connection.get_databricks_connection()

        assert "schema" not in seen


class TestJdbcSettings:
    def test_mysql_jdbc_streams_and_converts_zero_dates(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("MYSQL_HOST", "db")
        monkeypatch.setenv("MYSQL_USER", "reader")
        monkeypatch.setenv("MYSQL_DB", "source")
        monkeypatch.delenv("MYSQL_SERVER_TZ", raising=False)

        opts = connection.mysql_jdbc()

        assert opts["url"].startswith("jdbc:mysql://db:3306/source?")
        assert "useCursorFetch=true" in opts["url"]
        assert "zeroDateTimeBehavior=CONVERT_TO_NULL" in opts["url"]
        assert "serverTimezone=UTC" in opts["url"]
        assert opts["driver"] == "com.mysql.cj.jdbc.Driver"

    def test_pg_jdbc_batches_and_keeps_secrets_out_of_url(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("PG_HOST", "db")
        monkeypatch.setenv("PG_USER", "loader")
        monkeypatch.setenv("PG_DB", "warehouse")
        monkeypatch.setenv("PG_PASS", "secret")

        opts = connection.pg_jdbc()

        assert opts["url"] == (
            "jdbc:postgresql://db:5432/warehouse"
            "?reWriteBatchedInserts=true&stringtype=unspecified"
            "&ApplicationName=banking-spark"
        )
        assert opts["password"] == "secret"
        assert "secret" not in opts["url"]

    def test_mongo_settings_passes_database(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("MONGO_URI", "mongodb://db")
        monkeypatch.setenv("MONGO_DB_NAME", "source")

        assert connection.mongo_settings() == {
            "uri": "mongodb://db",
            "database": "source",
        }
