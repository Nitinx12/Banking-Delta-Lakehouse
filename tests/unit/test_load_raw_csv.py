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


class _Cur:
    def __init__(self, conn: "_Conn") -> None:
        self.conn = conn

    def __enter__(self) -> "_Cur":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def execute(self, query: str, params: tuple = ()) -> None:
        self.conn.calls.append((query, params))

    def fetchall(self) -> list[tuple[str, bool]]:
        return self.conn.columns

    def copy_expert(self, query: str, buffer: object) -> None:
        self.conn.copies.append((query, buffer.read()))


class _Conn:
    def __init__(self, columns: list[tuple[str, bool]] | None = None) -> None:
        self.columns = columns or []
        self.calls: list[tuple[str, tuple]] = []
        self.copies: list[tuple[str, str]] = []
        self.commits = 0
        self.rollbacks = 0
        self.closed = False

    def __enter__(self) -> "_Conn":
        return self

    def __exit__(self, *exc: object) -> None:
        return None

    def cursor(self, **kwargs: object) -> _Cur:
        return _Cur(self)

    def commit(self) -> None:
        self.commits += 1

    def rollback(self) -> None:
        self.rollbacks += 1

    def close(self) -> None:
        self.closed = True


def test_target_columns_maps_nullability(tmp_path: Path) -> None:
    conn = _Conn(columns=[("account_id", False), ("note", True)])

    assert load_raw_csv.target_columns(conn, "raw", "accounts") == {
        "account_id": False,
        "note": True,
    }
    assert "information_schema.columns" in conn.calls[0][0]
    assert conn.calls[0][1] == ("raw", "accounts")


def test_copy_batches_streams_strings_and_adds_metadata(tmp_path: Path) -> None:
    csv = tmp_path / "accounts.csv"
    csv.write_text("account_id,balance\n1,10.00\n2,20.00\n3,30.00\n", encoding="utf-8")
    conn = _Conn()

    rows = load_raw_csv.copy_batches(
        conn,
        "raw",
        "accounts",
        ["account_id", "balance", "_batch_id", "_loaded_at"],
        csv,
        2,
    )

    assert rows == 3
    assert len(conn.copies) == 2
    copy_sql, first = conn.copies[0]
    assert copy_sql.startswith('COPY raw."accounts"')
    assert first.startswith(
        "1,10.00,",
    )
    assert conn.copies[1][1].startswith("3,30.00,")


def test_ensure_columns_adds_missing_with_contract_types() -> None:
    conn = _Conn(columns=[("account_id", False)])

    load_raw_csv.ensure_columns(
        conn, "raw", "accounts", ["account_id", "extra"], _CONTRACT
    )

    statements = [sql for sql, _ in conn.calls]
    assert any('ADD COLUMN "extra" text' in sql for sql in statements)
    assert any('ADD COLUMN "_batch_id" text' in sql for sql in statements)
    assert any('ADD COLUMN "_loaded_at" timestamptz' in sql for sql in statements)
    assert not any('ADD COLUMN "account_id"' in sql for sql in statements)


def test_main_loads_each_table_and_closes_connection(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    folder = tmp_path / "mysql"
    folder.mkdir()
    (folder / "branches.csv").write_text("branch_id\n1\n", encoding="utf-8")
    conn = _Conn()
    loaded: list[str] = []
    monkeypatch.setattr(load_raw_csv, "get_pg_connection", lambda name: conn)
    monkeypatch.setattr(load_raw_csv, "require", lambda name: "value")
    monkeypatch.setattr(
        load_raw_csv,
        "load_table",
        lambda c, cfg, path, batch: loaded.append(cfg["target_table"]) or 1,
    )

    rc = load_raw_csv.main(["--data-dir", str(tmp_path), "--tables", "branches"])

    assert rc == 0
    assert loaded == ["branches"]
    assert conn.commits == 1
    assert conn.closed
    assert any("CREATE SCHEMA IF NOT EXISTS raw" in sql for sql, _ in conn.calls)


def test_main_rolls_back_failed_table_and_returns_one(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    folder = tmp_path / "mysql"
    folder.mkdir()
    (folder / "branches.csv").write_text("branch_id\n1\n", encoding="utf-8")
    conn = _Conn()
    monkeypatch.setattr(load_raw_csv, "get_pg_connection", lambda name: conn)
    monkeypatch.setattr(load_raw_csv, "require", lambda name: "value")

    def _fail(*args: object, **kwargs: object) -> int:
        raise RuntimeError("bad copy")

    monkeypatch.setattr(load_raw_csv, "load_table", _fail)

    rc = load_raw_csv.main(["--data-dir", str(tmp_path), "--tables", "branches"])

    assert rc == 1
    assert conn.rollbacks == 1
    assert conn.closed


def test_main_reports_missing_requested_table(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        load_raw_csv, "get_pg_connection", lambda name: pytest.fail("must not connect")
    )

    assert load_raw_csv.main(["--data-dir", str(tmp_path), "--tables", "branches"]) == 1
