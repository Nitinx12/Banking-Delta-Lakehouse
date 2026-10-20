"""Validate every contract under contracts/ against the JSON schemas.

Run:  uv run python -m contracts.validate            # all contracts
      uv run python -m contracts.validate <paths...> # specific files
Exit 0 only when every contract is valid. Used by pre-commit and CI.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS_DIR = ROOT / "contracts"
_PG_TYPES = {
    "bigint",
    "integer",
    "smallint",
    "numeric(18,2)",
    "numeric(5,2)",
    "double precision",
    "boolean",
    "text",
    "date",
    "timestamptz",
    "jsonb",
}
_SOURCES = {"mongodb_source", "mysql_source", "databricks_source"}
_LOAD = {"full", "incremental"}
_STRATEGY = {"timestamp", "numeric", "objectid"}
_MATCH = {"strict_gt", "inclusive_gte"}
_FRESHNESS = {"max_loaded_at_within_window", "none"}
_ROWCOUNT = {"source_vs_landed_exact", "source_vs_landed_tolerant"}
_SEVERITY = {"ERROR", "WARNING"}
_REQUIRED = {
    "contract_version",
    "name",
    "description",
    "source",
    "source_schema",
    "source_table",
    "target_schema",
    "target_table",
    "business_key",
    "load_strategy",
    "columns",
    "quality",
}
_IDENT = "abcdefghijklmnopqrstuvwxyz0123456789_"


class ContractError(ValueError):
    """A contract file is structurally or semantically wrong."""


def _is_ident(value: Any) -> bool:
    return (
        isinstance(value, str)
        and value != ""
        and value[0].isalpha()
        and value[0].islower()
        and all(ch in _IDENT for ch in value)
    )


def _is_column(value: Any) -> bool:
    if not isinstance(value, str) or value == "":
        return False
    body = value[1:] if value.startswith("_") else value
    return (
        body != ""
        and body[0].isalpha()
        and body[0].islower()
        and all(ch in _IDENT for ch in body)
    )


def _in(value: Any, allowed: set[str], label: str) -> None:
    if value not in allowed:
        raise ContractError(f"{label}: {value!r} not in {sorted(allowed)}")


def _column_list(value: Any, label: str) -> None:
    if not isinstance(value, list) or not value:
        raise ContractError(f"{label}: must be a non-empty array")
    for item in value:
        if not _is_column(item):
            raise ContractError(f"{label}: {item!r} is not a snake_case column name")


def _duration(value: Any, label: str) -> None:
    if not isinstance(value, str) or not value.startswith("PT"):
        raise ContractError(f"{label}: expected an ISO-8601 duration like 'PT6H'")
    body = value[2:]
    if not body or not any(ch.isdigit() for ch in body):
        raise ContractError(f"{label}: malformed duration {value!r}")


def validate_contract(data: dict[str, Any], *, path: str = "<dict>") -> None:
    """Raise ContractError if the contract is invalid (schema is the source of truth)."""
    if not isinstance(data, dict):
        raise ContractError(f"{path}: top level must be an object")
    missing = sorted(_REQUIRED - data.keys())
    if missing:
        raise ContractError(f"{path}: missing required keys {missing}")

    if data["contract_version"] != 1:
        raise ContractError(f"{path}: contract_version must be 1")
    if not _is_ident(data["name"]):
        raise ContractError(f"{path}: name must be snake_case")
    if not isinstance(data["description"], str) or len(data["description"]) < 8:
        raise ContractError(f"{path}: description must be at least 8 characters")
    _in(data["source"], _SOURCES, f"{path}: source")
    if data["target_schema"] != "raw":
        raise ContractError(
            f"{path}: target_schema must be 'raw' for a landing contract"
        )
    if not _is_ident(data["target_table"]):
        raise ContractError(f"{path}: target_table must be snake_case")

    _in(data["load_strategy"], _LOAD, f"{path}: load_strategy")
    if data["load_strategy"] == "incremental":
        if not _is_column(data.get("incremental_column")):
            raise ContractError(
                f"{path}: incremental tables need a snake_case incremental_column"
            )
        _in(data.get("watermark_strategy"), _STRATEGY, f"{path}: watermark_strategy")
    else:
        if data.get("incremental_column") is not None:
            raise ContractError(
                f"{path}: full-load tables must not set incremental_column"
            )
        if data.get("watermark_strategy") is not None:
            raise ContractError(
                f"{path}: full-load tables must not set watermark_strategy"
            )

    if "lookback" in data and data["lookback"] is not None:
        _duration(data["lookback"], f"{path}: lookback")

    if "match_mode" in data and data["match_mode"] is not None:
        _in(data["match_mode"], _MATCH, f"{path}: match_mode")

    _column_list(data["business_key"], f"{path}: business_key")

    columns = data["columns"]
    if not isinstance(columns, list) or not columns:
        raise ContractError(f"{path}: columns must be a non-empty array")
    names = []
    for column in columns:
        if not isinstance(column, dict):
            raise ContractError(f"{path}: each column must be an object")
        if not _is_column(column.get("name")):
            raise ContractError(
                f"{path}: column name {column.get('name')!r} is not snake_case"
            )
        if column.get("type") not in _PG_TYPES:
            raise ContractError(
                f"{path}: column {column['name']} has unsupported type {column.get('type')!r}"
            )
        names.append(column["name"])
    duplicates = sorted({n for n in names if names.count(n) > 1})
    if duplicates:
        raise ContractError(f"{path}: duplicate column names {duplicates}")
    declared_keys = set(names)
    for key in data["business_key"]:
        if key not in declared_keys:
            raise ContractError(
                f"{path}: business_key column {key!r} is not in columns"
            )

    quality = data["quality"]
    if not isinstance(quality, dict):
        raise ContractError(f"{path}: quality must be an object")
    row_count = quality.get("row_count", {})
    if not isinstance(row_count, dict):
        raise ContractError(f"{path}: quality.row_count must be an object")
    _in(row_count.get("mode"), _ROWCOUNT, f"{path}: quality.row_count.mode")
    _in(row_count.get("severity"), _SEVERITY, f"{path}: quality.row_count.severity")
    if (
        row_count["mode"] == "source_vs_landed_tolerant"
        and "tolerance_ratio" not in row_count
    ):
        raise ContractError(f"{path}: tolerant row_count needs tolerance_ratio")

    freshness = quality.get("freshness", {})
    if not isinstance(freshness, dict):
        raise ContractError(f"{path}: quality.freshness must be an object")
    _in(freshness.get("mode"), _FRESHNESS, f"{path}: quality.freshness.mode")
    _in(freshness.get("severity"), _SEVERITY, f"{path}: quality.freshness.severity")
    if freshness["mode"] != "none":
        _duration(freshness.get("window"), f"{path}: quality.freshness.window")


def _load(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        raise ContractError(f"{path}: invalid JSON: {exc}") from exc


def all_contract_paths() -> list[Path]:
    """Every contract source file (excluding JSON schemas)."""
    return sorted(
        p
        for p in CONTRACTS_DIR.rglob("*.json")
        if "schema" not in p.name
        and "example" not in p.parts
        and p.name != "registry.json"
    )


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    paths = [Path(a) for a in args] if args else all_contract_paths()

    failures: list[str] = []
    for path in paths:
        try:
            validate_contract(_load(path), path=str(path))
        except ContractError as exc:
            failures.append(str(exc))
    if failures:
        print("contract validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"contracts OK ({len(paths)} file(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
