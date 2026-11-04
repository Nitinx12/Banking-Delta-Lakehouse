"""list_raw_columns prints the raw schema grouped by table (no real DB)."""

from __future__ import annotations

import runpy
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]


class _Cur:
    def __init__(self, rows: list[tuple[str, str]]) -> None:
        self.rows = rows
        self.queries: list[str] = []

    def __enter__(self) -> "_Cur":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query: str) -> None:
        self.queries.append(query)

    def fetchall(self) -> list[tuple[str, str]]:
        return self.rows


class _Conn:
    def __init__(self, rows: list[tuple[str, str]]) -> None:
        self.cur = _Cur(rows)
        self.closed = False

    def __enter__(self) -> "_Conn":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def cursor(self) -> _Cur:
        return self.cur

    def close(self) -> None:
        self.closed = True


def test_prints_columns_grouped_by_table(monkeypatch: pytest.MonkeyPatch) -> None:
    conn = _Conn([("accounts", "id"), ("accounts", "balance"), ("branches", "id")])
    monkeypatch.setattr("psycopg2.connect", lambda **kw: conn)
    logged: list[tuple[str, tuple]] = []
    fake_logger = SimpleNamespace(
        info=lambda msg, *a: logged.append((msg, a)),
    )

    class _LoggerModule:
        @staticmethod
        def get_logger(name: str) -> object:
            return fake_logger

    monkeypatch.setitem(sys.modules, "src.utils.logger", _LoggerModule)

    runpy.run_path(str(ROOT / "scripts" / "list_raw_columns.py"), run_name="__main__")

    assert conn.cur.queries and "information_schema.columns" in conn.cur.queries[0]
    messages = [msg for msg, _ in logged]
    assert "accounts" in messages
    assert "branches" in messages
    assert ("  - %s", ("id",)) in logged
    assert ("  - %s", ("balance",)) in logged
