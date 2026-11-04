"""Unit tests for scripts/sync_contracts.py (contract generation from the registry)."""

from __future__ import annotations

import datetime as dt
import json
import sys
from collections import namedtuple
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import sync_contracts  # noqa: E402 - script path is set above


class _Cursor:
    def __init__(self, rows=()) -> None:
        self.rows = list(rows)

    def __enter__(self) -> "_Cursor":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query, params=None) -> None:
        self.query = query

    def fetchall(self):
        return self.rows


class _Conn:
    def __init__(self, rows=()) -> None:
        self.cur = _Cursor(rows)
        self.closed = False

    def cursor(self) -> _Cursor:
        return self.cur

    def close(self) -> None:
        self.closed = True


class _MongoCollection:
    def __init__(self, doc) -> None:
        self.doc = doc

    def find_one(self) -> dict | None:
        return self.doc


class _MongoDB:
    def __init__(self, doc) -> None:
        self.doc = doc

    def __getitem__(self, name: str) -> _MongoCollection:
        return _MongoCollection(self.doc)


class _MongoClient:
    def __init__(self, doc) -> None:
        self.doc = doc
        self.closed = False

    def __getitem__(self, name: str) -> _MongoDB:
        return _MongoDB(self.doc)

    def close(self) -> None:
        self.closed = True


def _entry(**overrides) -> dict:
    entry = {
        "source": "mysql_source",
        "source_schema": "bank",
        "source_table": "accounts",
        "target_schema": "raw",
        "target_table": "accounts",
        "business_key": ["id"],
        "load_strategy": "full",
    }
    entry.update(overrides)
    return entry


class TestMoney:
    @pytest.mark.parametrize(
        ("name", "expected"),
        [
            ("amount", True),
            ("Loan_Balance", True),
            ("monthly_income", True),
            ("credit_limit", True),
            ("salary", True),
            ("unit_price", True),
            ("shipping_cost", True),
            ("customer_name", False),
            ("interest_rate", False),
        ],
    )
    def test_money_tokens(self, name: str, expected: bool) -> None:
        assert sync_contracts._is_money(name) is expected


class TestTypeMappings:
    @pytest.mark.parametrize(
        ("dtype", "name", "expected"),
        [
            ("int", "id", "bigint"),
            ("bigint", "id", "bigint"),
            ("decimal(10,2)", "amount", "numeric(18,2)"),
            ("numeric", "amount", "numeric(18,2)"),
            ("varchar", "name", "text"),
            ("longtext", "notes", "text"),
            ("date", "opened_on", "date"),
            ("datetime", "updated_at", "timestamptz"),
            ("timestamp", "updated_at", "timestamptz"),
            ("double", "amount", "numeric(18,2)"),
            ("double", "score", "double precision"),
            ("float", "rate", "double precision"),
            ("boolean", "is_active", "boolean"),
            ("tinyint", "is_active", "bigint"),
            ("geometry", "shape", "text"),
        ],
    )
    def test_mysql(self, dtype: str, name: str, expected: str) -> None:
        assert sync_contracts._map_mysql(dtype, name) == expected

    @pytest.mark.parametrize(
        ("dtype", "name", "expected"),
        [
            ("int", "id", "bigint"),
            ("string", "name", "text"),
            ("double", "amount", "numeric(18,2)"),
            ("double", "score", "double precision"),
            ("date", "opened_on", "date"),
            ("timestamp", "updated_at", "timestamptz"),
            ("decimal(18,2)", "amount", "numeric(18,2)"),
            ("boolean", "is_active", "boolean"),
            ("binary", "blob", "text"),
        ],
    )
    def test_databricks(self, dtype: str, name: str, expected: str) -> None:
        assert sync_contracts._map_databricks(dtype, name) == expected

    @pytest.mark.parametrize(
        ("name", "value", "expected"),
        [
            ("_id", "64b000000000000000000000", "text"),
            ("is_active", True, "boolean"),
            ("score", 5, "integer"),
            ("customer_id", 5, "bigint"),
            ("amount", 1.5, "numeric(18,2)"),
            ("rate", 1.5, "double precision"),
            ("created_at", dt.datetime(2024, 5, 1), "timestamptz"),
            ("amount", "10.00", "numeric(18,2)"),
            ("created_at", "2024-05-01T00:00:00", "timestamptz"),
            ("snapshot_timestamp", "x", "timestamptz"),
            ("opened_date", "2024-05-01", "date"),
            ("birth_date", "2024-05-01", "date"),
            ("customer_id", "123", "bigint"),
            ("customer_id", "abc", "text"),
            ("credit_score", "750", "integer"),
            ("is_active", "1", "integer"),
            ("deleted_flag", "0", "integer"),
            ("name", "Alice", "text"),
        ],
    )
    def test_mongo_inference(self, name: str, value, expected: str) -> None:
        assert sync_contracts._infer_mongo(name, value) == expected


class TestSourceColumns:
    def test_mysql_columns_drop_audit_fields(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        conn = _Conn(
            [
                ("id", "int", "NO"),
                ("_batch_id", "varchar", "NO"),
                ("amount", "double", "YES"),
            ]
        )
        monkeypatch.setattr("src.utils.connection.get_mysql_connection", lambda: conn)

        columns = sync_contracts._mysql_columns("bank", "accounts")

        assert columns == [("id", "int", False), ("amount", "double", True)]
        assert conn.closed

    def test_mongo_columns_infer_and_skip_audit(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        client = _MongoClient(
            {"_id": "abc", "_batch_id": "x", "name": "Alice", "amount": 1.5}
        )
        monkeypatch.setattr("src.utils.connection.get_mongo_client", lambda: client)

        columns = sync_contracts._mongo_columns("bank", "customers")

        assert columns == [
            ("_id", "text", True),
            ("name", "text", True),
            ("amount", "numeric(18,2)", True),
        ]
        assert client.closed

    def test_mongo_columns_empty_collection(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            "src.utils.connection.get_mongo_client", lambda: _MongoClient(None)
        )

        assert sync_contracts._mongo_columns("bank", "empty") == []

    def test_databricks_columns_handle_objects_and_sections(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        Row = namedtuple("Row", "col_name data_type")
        conn = _Conn(
            [
                Row("id", "bigint"),
                ("name", "string"),
                ("# Partitioning", ""),
                ("", ""),
                ("_batch_id", "string"),
            ]
        )
        monkeypatch.setattr(
            "src.utils.connection.get_databricks_connection", lambda: conn
        )

        columns = sync_contracts._databricks_columns("public", "branches")

        assert columns == [("id", "bigint", True), ("name", "string", True)]
        assert conn.closed


class TestColumnsFor:
    def test_mysql_columns_are_mapped_and_keys_marked_not_null(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            sync_contracts,
            "_mysql_columns",
            lambda s, t: [("id", "int", True), ("amount", "double", True)],
        )

        columns = sync_contracts._columns_for(_entry())

        assert columns == [
            {"name": "id", "type": "bigint", "nullable": False, "key": True},
            {"name": "amount", "type": "numeric(18,2)", "nullable": True},
        ]

    def test_mongo_columns_keep_inferred_types(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            sync_contracts,
            "_mongo_columns",
            lambda s, t: [("_id", "text", True), ("score", "integer", True)],
        )

        columns = sync_contracts._columns_for(
            _entry(source="mongodb_source", business_key=["_id"])
        )

        assert columns[0]["key"] is True and columns[0]["nullable"] is False
        assert columns[1] == {"name": "score", "type": "integer", "nullable": True}

    def test_databricks_columns_are_mapped(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            sync_contracts,
            "_databricks_columns",
            lambda s, t: [("id", "bigint", True), ("name", "string", True)],
        )

        columns = sync_contracts._columns_for(
            _entry(source="databricks_source", business_key=["id"])
        )

        assert columns == [
            {"name": "id", "type": "bigint", "nullable": False, "key": True},
            {"name": "name", "type": "text", "nullable": True},
        ]

    def test_unknown_source_raises(self) -> None:
        with pytest.raises(ValueError, match="unknown source"):
            sync_contracts._columns_for(_entry(source="oracle_source"))


class TestBuildContract:
    def test_full_load_contract_has_no_incremental_fields(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            sync_contracts, "_columns_for", lambda e: [{"name": "id", "type": "bigint"}]
        )

        contract = sync_contracts._build_contract(_entry())

        assert contract["incremental_column"] is None
        assert contract["watermark_strategy"] is None
        assert "num_partitions" not in contract
        assert contract["quality"] is sync_contracts.QUALITY
        assert contract["tags"] == ["auto-generated"]

    def test_incremental_timestamp_uses_strict_gt(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(sync_contracts, "_columns_for", lambda e: [])
        entry = _entry(
            load_strategy="incremental",
            incremental_column="updated_at",
            watermark_strategy="timestamp",
            num_partitions=4,
        )

        contract = sync_contracts._build_contract(entry)

        assert contract["incremental_column"] == "updated_at"
        assert contract["watermark_strategy"] == "timestamp"
        assert contract["match_mode"] == "strict_gt"
        assert contract["num_partitions"] == 4

    def test_incremental_objectid_has_no_match_mode(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(sync_contracts, "_columns_for", lambda e: [])
        entry = _entry(
            source="mongodb_source",
            load_strategy="incremental",
            incremental_column="_id",
            watermark_strategy="objectid",
            num_partitions=0,
        )

        contract = sync_contracts._build_contract(entry)

        assert "match_mode" not in contract
        assert "num_partitions" not in contract


class TestContractPath:
    @pytest.mark.parametrize(
        ("source", "folder"),
        [
            ("mysql_source", "mysql"),
            ("mongodb_source", "mongodb"),
            ("databricks_source", "databricks"),
        ],
    )
    def test_path_uses_source_folder(
        self,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
        source: str,
        folder: str,
    ) -> None:
        monkeypatch.setattr(sync_contracts, "CONTRACTS_DIR", tmp_path)

        path = sync_contracts._contract_path(
            _entry(source=source, target_table="accounts")
        )

        assert path == tmp_path / folder / "accounts.json"


class TestMain:
    def _registry(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, entries: list[dict]
    ) -> Path:
        registry = tmp_path / "registry.json"
        registry.write_text(json.dumps({"tables": entries}), encoding="utf-8")
        monkeypatch.setattr(sync_contracts, "REGISTRY_PATH", registry)
        monkeypatch.setattr(sync_contracts, "CONTRACTS_DIR", tmp_path / "contracts")
        return registry

    def test_creates_missing_contracts(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        self._registry(tmp_path, monkeypatch, [_entry()])
        monkeypatch.setattr(sync_contracts, "_columns_for", lambda e: [])
        import contracts.validate as validate

        monkeypatch.setattr(validate, "validate_contract", lambda *a, **k: None)

        assert sync_contracts.main([]) == 0
        written = json.loads(
            (tmp_path / "contracts" / "mysql" / "accounts.json").read_text("utf-8")
        )
        assert written["name"] == "accounts"

    def test_existing_contracts_are_skipped_without_update(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        self._registry(tmp_path, monkeypatch, [_entry()])
        target = tmp_path / "contracts" / "mysql" / "accounts.json"
        target.parent.mkdir(parents=True)
        target.write_text('{"original": true}', encoding="utf-8")
        built: list[dict] = []
        monkeypatch.setattr(
            sync_contracts, "_build_contract", lambda e: built.append(e) or {}
        )
        import contracts.validate as validate

        monkeypatch.setattr(validate, "validate_contract", lambda *a, **k: None)

        assert sync_contracts.main([]) == 0
        assert built == []
        assert json.loads(target.read_text("utf-8")) == {"original": True}

    def test_update_regenerates_existing_contract(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        self._registry(tmp_path, monkeypatch, [_entry()])
        target = tmp_path / "contracts" / "mysql" / "accounts.json"
        target.parent.mkdir(parents=True)
        target.write_text("{}", encoding="utf-8")
        monkeypatch.setattr(
            sync_contracts, "_build_contract", lambda e: {"fresh": True}
        )
        import contracts.validate as validate

        monkeypatch.setattr(validate, "validate_contract", lambda *a, **k: None)

        assert sync_contracts.main(["--update"]) == 0
        assert json.loads(target.read_text("utf-8")) == {"fresh": True}

    def test_dry_run_writes_nothing(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        self._registry(tmp_path, monkeypatch, [_entry()])
        monkeypatch.setattr(
            sync_contracts, "_build_contract", lambda e: {"fresh": True}
        )
        import contracts.validate as validate

        monkeypatch.setattr(validate, "validate_contract", lambda *a, **k: None)

        assert sync_contracts.main(["--dry-run"]) == 0
        assert not (tmp_path / "contracts" / "mysql" / "accounts.json").exists()

    def test_invalid_contract_is_reported_and_skipped(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        self._registry(tmp_path, monkeypatch, [_entry()])
        monkeypatch.setattr(sync_contracts, "_build_contract", lambda e: {"bad": True})
        import contracts.validate as validate

        def _reject(*args, **kwargs):
            raise ValueError("contract invalid")

        monkeypatch.setattr(validate, "validate_contract", _reject)

        assert sync_contracts.main([]) == 0
        assert not (tmp_path / "contracts" / "mysql" / "accounts.json").exists()
