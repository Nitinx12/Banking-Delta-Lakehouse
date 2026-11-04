"""Unit tests for scripts/export_raw_csv.py (CSV snapshot export)."""

from __future__ import annotations

import datetime as dt
import gzip
import json
import sys
from decimal import Decimal
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import export_raw_csv  # noqa: E402 - script path is set above


class _MyCursor:
    def __init__(self, rows=(), description=()) -> None:
        self.rows = list(rows)
        self.description = list(description)
        self.calls: list[str] = []

    def __enter__(self) -> "_MyCursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query: str) -> None:
        self.calls.append(query)

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall_unbuffered(self):
        return iter(self.rows)


class _MyConn:
    def __init__(self, count_cursor: _MyCursor, data_cursor: _MyCursor) -> None:
        self.count_cursor = count_cursor
        self.data_cursor = data_cursor
        self.kinds: list = []

    def __enter__(self) -> "_MyConn":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def cursor(self, kind=None) -> _MyCursor:
        self.kinds.append(kind)
        return self.data_cursor if kind else self.count_cursor


class _MongoCollection:
    def __init__(self, docs) -> None:
        self.docs = docs

    def estimated_document_count(self) -> int:
        return len(self.docs)

    def find(self, flt) -> "_DocsCursor":
        assert flt == {}
        return _DocsCursor(iter(self.docs))


class _DocsCursor:
    def __init__(self, docs) -> None:
        self.docs = docs

    def __iter__(self):
        return self

    def __next__(self):
        return next(self.docs)


class _MongoClient:
    def __init__(self, docs) -> None:
        self.docs = docs
        self.closed = False

    def __getitem__(self, name: str) -> "_MongoDB":
        return _MongoDB(self.docs)

    def close(self) -> None:
        self.closed = True


class _MongoDB:
    def __init__(self, docs) -> None:
        self.docs = docs

    def __getitem__(self, name: str) -> _MongoCollection:
        return _MongoCollection(self.docs)


class _DbxCursor:
    def __init__(self, batches, description) -> None:
        self.batches = list(batches)
        self.description = description
        self.calls: list[str] = []

    def execute(self, query: str) -> None:
        self.calls.append(query)

    def fetchmany(self, n: int):
        return self.batches.pop(0) if self.batches else []


class _DbxConn:
    def __init__(self, batches, description) -> None:
        self.cur = _DbxCursor(batches, description)
        self.closed = False

    def cursor(self) -> _DbxCursor:
        return self.cur

    def close(self) -> None:
        self.closed = True


def _read_gz(path: Path) -> str:
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        return fh.read()


class TestCell:
    @pytest.mark.parametrize(
        ("value", "expected"),
        [
            (None, ""),
            (dt.datetime(2024, 5, 1, 10, 0), "2024-05-01T10:00:00"),
            (dt.date(2024, 5, 1), "2024-05-01"),
            (Decimal("10.50"), "10.50"),
            ("plain", "plain"),
            (7, 7),
        ],
    )
    def test_cell_conversion(self, value, expected) -> None:
        assert export_raw_csv._cell(value) == expected


class TestWrite:
    def test_writes_gzip_and_replaces_part_file(self, tmp_path: Path) -> None:
        dest = tmp_path / "nested" / "table.csv.gz"

        written = export_raw_csv._write(
            dest, ["id", "name"], iter([[1, "a"], [2, "b"]]), None
        )

        assert written == 2
        assert _read_gz(dest) == "id,name\n1,a\n2,b\n"
        assert not dest.with_suffix(".csv.gz.part").exists()

    def test_limit_stops_early(self, tmp_path: Path) -> None:
        dest = tmp_path / "table.csv.gz"
        rows = ((i,) for i in range(10))

        written = export_raw_csv._write(dest, ["id"], rows, limit=3)

        assert written == 3
        assert _read_gz(dest).count("\n") == 4  # header + 3 rows


class TestExportMysql:
    def test_streams_rows_and_applies_limit(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        count = _MyCursor([(2,)])
        data = _MyCursor([(1, "a"), (2, "b")], description=[("id",), ("name",)])
        conn = _MyConn(count, data)
        monkeypatch.setattr(export_raw_csv, "get_mysql_connection", lambda: conn)
        dest = tmp_path / "accounts.csv.gz"

        written = export_raw_csv.export_mysql(
            {"source_table": "accounts"}, dest, limit=10
        )

        assert written == 2
        assert data.calls == ["SELECT * FROM accounts LIMIT 10"]
        assert conn.kinds[0] is None
        assert conn.kinds[1] is export_raw_csv.pymysql.cursors.SSCursor
        assert _read_gz(dest) == "id,name\n1,a\n2,b\n"


class TestExportMongo:
    def test_sorted_columns_and_rows(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        client = _MongoClient([{"b": 2, "a": 1}, {"b": 3, "a": 4}])
        monkeypatch.setattr(export_raw_csv, "get_mongo_client", lambda: client)
        monkeypatch.setattr(export_raw_csv, "require", lambda key: "bank")
        dest = tmp_path / "loans.csv.gz"

        written = export_raw_csv.export_mongo({"source_table": "loans"}, dest, None)

        assert written == 2
        assert _read_gz(dest) == "a,b\n1,2\n4,3\n"
        assert client.closed

    def test_empty_collection_writes_header_only(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setattr(
            export_raw_csv, "get_mongo_client", lambda: _MongoClient([])
        )
        monkeypatch.setattr(export_raw_csv, "require", lambda key: "bank")
        dest = tmp_path / "loans.csv.gz"

        assert export_raw_csv.export_mongo({"source_table": "loans"}, dest, None) == 0
        assert _read_gz(dest) == "\n"

    def test_schema_drift_mid_export_raises(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        client = _MongoClient([{"a": 1}, {"b": 2}])
        monkeypatch.setattr(export_raw_csv, "get_mongo_client", lambda: client)
        monkeypatch.setattr(export_raw_csv, "require", lambda key: "bank")
        dest = tmp_path / "loans.csv.gz"

        with pytest.raises(RuntimeError, match="schema drift mid-export"):
            export_raw_csv.export_mongo({"source_table": "loans"}, dest, None)
        assert client.closed
        assert not dest.exists()


class TestExportDatabricks:
    def test_fetches_batches_into_csv(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        conn = _DbxConn([[(1, "a"), (2, "b")], []], description=[("id",), ("name",)])
        monkeypatch.setattr(export_raw_csv, "get_databricks_connection", lambda: conn)
        monkeypatch.setattr(export_raw_csv, "dbx_call", lambda label, fn: fn())
        dest = tmp_path / "branches.csv.gz"
        cfg = {"source_schema": "public", "source_table": "branches"}

        written = export_raw_csv.export_databricks(cfg, dest, limit=5)

        assert written == 2
        assert conn.cur.calls == ["SELECT * FROM public.branches LIMIT 5"]
        assert _read_gz(dest) == "id,name\n1,a\n2,b\n"
        assert conn.closed

    @pytest.mark.parametrize(
        "cfg",
        [
            {"source_schema": "public", "source_table": "bad-name"},
            {"source_schema": "bad schema", "source_table": "branches"},
        ],
    )
    def test_unsafe_identifiers_are_rejected(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path, cfg: dict
    ) -> None:
        called: list = []
        monkeypatch.setattr(
            export_raw_csv, "get_databricks_connection", lambda: called.append(1)
        )

        with pytest.raises(RuntimeError, match="unsafe identifier"):
            export_raw_csv.export_databricks(cfg, tmp_path / "x.csv.gz", None)
        assert called == []


class TestRegistryAndMain:
    def test_load_registry_filters_by_source(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        registry = tmp_path / "registry.json"
        registry.write_text(
            json.dumps(
                {
                    "tables": [
                        {"source": "mysql_source", "target_table": "accounts"},
                        {"source": "mongodb_source", "target_table": "loans"},
                    ]
                }
            ),
            encoding="utf-8",
        )
        monkeypatch.setattr(export_raw_csv, "REGISTRY", registry)

        tables = export_raw_csv.load_registry({"mongodb_source"})

        assert tables == [{"source": "mongodb_source", "target_table": "loans"}]

    def _registry(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        registry = tmp_path / "registry.json"
        registry.write_text(
            json.dumps(
                {
                    "tables": [
                        {"source": "mysql_source", "target_table": "accounts"},
                        {"source": "mongodb_source", "target_table": "loans"},
                    ]
                }
            ),
            encoding="utf-8",
        )
        monkeypatch.setattr(export_raw_csv, "REGISTRY", registry)

    def test_main_exports_only_selected_folders(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        self._registry(tmp_path, monkeypatch)
        calls: list[tuple] = []
        monkeypatch.setattr(
            export_raw_csv,
            "EXPORTERS",
            {
                "mysql_source": lambda cfg, dest, limit: calls.append(
                    ("mysql", cfg["target_table"], dest.name, limit)
                )
                or 3,
                "mongodb_source": lambda cfg, dest, limit: calls.append(
                    ("mongo", cfg["target_table"], dest.name, limit)
                )
                or 4,
            },
        )

        code = export_raw_csv.main(
            ["--sources", "mysql", "--data-dir", str(tmp_path), "--limit", "7"]
        )

        assert code == 0
        assert calls == [("mysql", "accounts", "accounts.csv.gz", 7)]

    def test_main_reports_failed_exports(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        self._registry(tmp_path, monkeypatch)

        def _boom(cfg, dest, limit):
            raise RuntimeError("source down")

        monkeypatch.setattr(
            export_raw_csv,
            "EXPORTERS",
            {"mysql_source": _boom, "mongodb_source": _boom},
        )

        assert export_raw_csv.main(["--data-dir", str(tmp_path)]) == 1

    def test_rejects_unknown_source_folder(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        with pytest.raises(SystemExit):
            export_raw_csv.main(["--sources", "oracle"])
