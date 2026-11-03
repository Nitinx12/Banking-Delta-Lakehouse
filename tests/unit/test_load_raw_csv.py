"""load_raw_csv builds tables from contracts and picks COPY columns without a DB."""

from __future__ import annotations

import gzip
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import load_raw_csv  # noqa: E402 - script path is set above

_CONTRACT = {
    "target_table": "accounts",
    "columns": [
        {"name": "account_id", "type": "bigint", "nullable": False},
        {"name": "balance", "type": "numeric(18,2)", "nullable": True},
        {"name": "note", "type": "text", "nullable": False},
    ],
}


def test_create_table_sql_uses_contract_types_and_metadata() -> None:
    ddl = load_raw_csv.create_table_sql("raw", _CONTRACT)
    assert ddl == (
        'CREATE TABLE IF NOT EXISTS raw."accounts" ('
        '"account_id" bigint NOT NULL, '
        '"balance" numeric(18,2), '
        '"note" text NOT NULL, '
        '"_batch_id" text NOT NULL, '
        '"_loaded_at" timestamptz NOT NULL)'
    )


def test_create_table_sql_rejects_unsafe_contract_type() -> None:
    bad = {
        "target_table": "accounts",
        "columns": [{"name": "x", "type": "text); DROP"}],
    }
    with pytest.raises(ValueError, match="unsafe column"):
        load_raw_csv.create_table_sql("raw", bad)


def test_select_columns_for_new_table_skips_missing_nullable() -> None:
    contract = {
        "target_table": "t",
        "columns": [
            {"name": "a", "type": "bigint", "nullable": False},
            {"name": "b", "type": "text", "nullable": True},
        ],
    }
    cols = load_raw_csv.select_columns(["a"], target=None, contract=contract)
    assert cols == ["a", "_batch_id", "_loaded_at"]


def test_select_columns_for_new_table_requires_missing_not_null() -> None:
    with pytest.raises(ValueError, match="missing required columns: \\['note'\\]"):
        load_raw_csv.select_columns(["account_id"], target=None, contract=_CONTRACT)


def test_select_columns_for_existing_table_follows_contract_then_header() -> None:
    target = {"balance": True, "account_id": False, "legacy_col": True}
    header = ["note", "account_id", "legacy_col", "balance"]
    cols = load_raw_csv.select_columns(header, target=target, contract=_CONTRACT)
    assert cols == [
        "account_id",
        "balance",
        "legacy_col",
        "_batch_id",
        "_loaded_at",
    ]


def test_data_file_prefers_fresh_export_over_shipped_gzip(tmp_path: Path) -> None:
    cfg = {"source": "mysql_source", "target_table": "branches"}
    folder = tmp_path / "mysql"
    folder.mkdir()
    plain = folder / "branches.csv"
    gz = folder / "branches.csv.gz"
    assert load_raw_csv.data_file(tmp_path, cfg) is None
    with gzip.open(gz, "wt", encoding="utf-8") as fh:
        fh.write("branch_id\n1\n")
    assert load_raw_csv.data_file(tmp_path, cfg) == gz
    plain.write_text("branch_id\n1\n", encoding="utf-8")
    assert load_raw_csv.data_file(tmp_path, cfg) == plain


def test_dry_run_never_touches_the_database(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def _explode(*args: object, **kwargs: object) -> None:
        raise AssertionError("dry-run must not connect")

    monkeypatch.setattr(load_raw_csv, "get_pg_connection", _explode)
    folder = tmp_path / "mysql"
    folder.mkdir()
    (folder / "branches.csv").write_text("branch_id\n1\n", encoding="utf-8")
    rc = load_raw_csv.main(
        ["--dry-run", "--data-dir", str(tmp_path), "--tables", "branches"]
    )
    assert rc == 0
    empty = tmp_path / "empty"
    empty.mkdir()
    assert load_raw_csv.main(["--dry-run", "--data-dir", str(empty)]) == 1


def test_registry_entries_have_matching_contracts() -> None:
    for cfg in load_raw_csv.registry_tables():
        contract = load_raw_csv.contract_for(cfg)
        assert contract["target_table"] == cfg["target_table"]
        assert contract["source"] == cfg["source"]
