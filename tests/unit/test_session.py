"""Unit tests for src/utils/session.py (Spark singleton, transactions, cursors)."""

from __future__ import annotations

from contextlib import contextmanager

import pytest
import psycopg2.extras

from src.utils import session

pytestmark = pytest.mark.unit


class _FakeConn:
    def __init__(self) -> None:
        self.committed = 0
        self.rolled_back = 0
        self.closed = False
        self.factories: list = []

    def commit(self) -> None:
        self.committed += 1

    def rollback(self) -> None:
        self.rolled_back += 1

    def close(self) -> None:
        self.closed = True

    def cursor(self, cursor_factory=None) -> "_FakeCursor":
        self.factories.append(cursor_factory)
        return _FakeCursor()


class _FakeCursor:
    def __enter__(self) -> "_FakeCursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None


class _FakeSpark:
    def __init__(self) -> None:
        self.stopped = False

    def stop(self) -> None:
        self.stopped = True


class TestSparkSingleton:
    def test_session_is_created_once_and_reused(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        created: list[dict] = []
        fake = _FakeSpark()
        monkeypatch.setattr(session, "_spark", None)
        monkeypatch.setattr(
            session,
            "get_spark",
            lambda **kw: created.append(kw) or fake,
        )
        try:
            first = session.get_spark_session("app", sources=("mysql",))
            second = session.get_spark_session("other")
        finally:
            session._spark = None

        assert first is second is fake
        assert created == [{"app_name": "app", "sources": ("mysql",)}]

    def test_stop_spark_stops_and_clears(self, monkeypatch: pytest.MonkeyPatch) -> None:
        fake = _FakeSpark()
        monkeypatch.setattr(session, "_spark", fake)

        session.stop_spark()

        assert fake.stopped
        assert session._spark is None

    def test_stop_spark_is_a_noop_without_session(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(session, "_spark", None)

        session.stop_spark()

        assert session._spark is None


class TestPgTransaction:
    def test_commits_and_closes_on_success(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _FakeConn()
        monkeypatch.setattr(session, "get_pg_connection", lambda name: conn)

        with session.pg_transaction("app") as yielded:
            assert yielded is conn

        assert conn.committed == 1
        assert conn.rolled_back == 0
        assert conn.closed

    def test_rolls_back_and_reraises_on_error(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _FakeConn()
        monkeypatch.setattr(session, "get_pg_connection", lambda name: conn)

        with pytest.raises(RuntimeError, match="boom"):
            with session.pg_transaction():
                raise RuntimeError("boom")

        assert conn.committed == 0
        assert conn.rolled_back == 1
        assert conn.closed


class TestPgCursor:
    def test_default_cursor_has_no_factory(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _FakeConn()

        @contextmanager
        def _tx():
            yield conn

        monkeypatch.setattr(session, "pg_transaction", _tx)

        with session.pg_cursor() as cur:
            assert isinstance(cur, _FakeCursor)

        assert conn.factories == [None]

    def test_dict_rows_uses_real_dict_cursor(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _FakeConn()

        @contextmanager
        def _tx():
            yield conn

        monkeypatch.setattr(session, "pg_transaction", _tx)

        with session.pg_cursor(dict_rows=True):
            pass

        assert conn.factories == [psycopg2.extras.RealDictCursor]


class TestMysqlCursor:
    def test_closes_connection_after_use(self, monkeypatch: pytest.MonkeyPatch) -> None:
        conn = _FakeConn()
        monkeypatch.setattr(session, "get_mysql_connection", lambda: conn)

        with session.mysql_cursor() as cur:
            assert isinstance(cur, _FakeCursor)

        assert conn.closed

    def test_closes_connection_on_error(self, monkeypatch: pytest.MonkeyPatch) -> None:
        conn = _FakeConn()
        monkeypatch.setattr(session, "get_mysql_connection", lambda: conn)

        with pytest.raises(ValueError):
            with session.mysql_cursor():
                raise ValueError("bad row")

        assert conn.closed


class _MongoClient:
    def __init__(self) -> None:
        self.closed = False
        self.requested: list[str] = []

    def __getitem__(self, name: str) -> str:
        self.requested.append(name)
        return f"db:{name}"

    def close(self) -> None:
        self.closed = True


class TestMongoDatabase:
    def test_explicit_name_wins(self, monkeypatch: pytest.MonkeyPatch) -> None:
        client = _MongoClient()
        monkeypatch.setattr(session, "get_mongo_client", lambda: client)

        with session.mongo_database("explicit") as db:
            assert db == "db:explicit"

        assert client.closed

    def test_env_name_is_used(self, monkeypatch: pytest.MonkeyPatch) -> None:
        client = _MongoClient()
        monkeypatch.setattr(session, "get_mongo_client", lambda: client)
        monkeypatch.setenv("MONGO_DB_NAME", "from-env")

        with session.mongo_database() as db:
            assert db == "db:from-env"

    def test_require_fallback_when_env_missing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        client = _MongoClient()
        monkeypatch.setattr(session, "get_mongo_client", lambda: client)
        monkeypatch.delenv("MONGO_DB_NAME", raising=False)
        monkeypatch.setattr("src.utils.config.require", lambda key: "from-config")

        with session.mongo_database() as db:
            assert db == "db:from-config"

        assert client.closed
