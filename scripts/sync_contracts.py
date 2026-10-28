"""Sync source-landing contracts with the source registry.

Generates a contract JSON for every table in contracts/registry.json that does not
already have one, by introspecting the live source system. Existing contracts are
left untouched unless --update is given. Run:

    uv run python scripts/sync_contracts.py [--update] [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from src.utils.logger import get_logger  # noqa: E402

logger = get_logger("sync_contracts")

CONTRACTS_DIR = ROOT / "contracts"
REGISTRY_PATH = CONTRACTS_DIR / "registry.json"
SOURCE_TO_DIR = {
    "mysql_source": "mysql",
    "mongodb_source": "mongodb",
    "databricks_source": "databricks",
}
AUDIT_COLUMNS = {"_batch_id", "_loaded_at", "loaded_at"}
MONEY_TOKENS = ("amount", "balance", "income", "limit", "salary", "price", "cost")
QUALITY = {
    "row_count": {"mode": "source_vs_landed_exact", "severity": "ERROR"},
    "freshness": {
        "mode": "max_loaded_at_within_window",
        "window": "PT24H",
        "compare": "landing_loaded_at",
        "severity": "WARNING",
    },
}


def _is_money(name: str) -> bool:
    lowered = name.lower()
    return any(token in lowered for token in MONEY_TOKENS)


def _mysql_columns(schema: str, table: str) -> list[tuple[str, str, bool]]:
    from src.utils.connection import get_mysql_connection

    conn = get_mysql_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s
                ORDER BY ORDINAL_POSITION
                """,
                (schema, table),
            )
            return [
                (name, dtype, nullable == "YES")
                for name, dtype, nullable in cur.fetchall()
                if name not in AUDIT_COLUMNS
            ]
    finally:
        conn.close()


def _map_mysql(dtype: str, name: str) -> str:
    d = dtype.lower()
    if "int" in d:
        return "bigint"
    if d.startswith("decimal") or d == "numeric":
        return "numeric(18,2)"
    if d in {"varchar", "char", "text", "longtext", "mediumtext", "tinytext"}:
        return "text"
    if d == "date":
        return "date"
    if d in {"datetime", "timestamp"}:
        return "timestamptz"
    if d in {"double", "float", "real"}:
        return "numeric(18,2)" if _is_money(name) else "double precision"
    if d in {"boolean", "tinyint"}:
        return "boolean"
    return "text"


def _mongo_columns(schema: str, table: str) -> list[tuple[str, str, bool]]:
    from src.utils.connection import get_mongo_client

    client = get_mongo_client()
    try:
        db = client[schema]
        doc = db[table].find_one()
        if not doc:
            return []
        result = []
        for key, value in doc.items():
            if key in AUDIT_COLUMNS:
                continue
            result.append((key, _infer_mongo(key, value), True))
        return result
    finally:
        client.close()


def _infer_mongo(name: str, value: Any) -> str:
    if name == "_id":
        return "text"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer" if "score" in name.lower() else "bigint"
    if isinstance(value, float):
        return "numeric(18,2)" if _is_money(name) else "double precision"
    if isinstance(value, datetime):
        return "timestamptz"
    if isinstance(value, str):
        if _is_money(name):
            return "numeric(18,2)"
        if name.endswith("_at") or "timestamp" in name:
            return "timestamptz"
        if name.endswith("_date") or "date" in name:
            return "date"
        if name.endswith("_id") and value.isdigit():
            return "bigint"
        if "score" in name:
            return "integer"
        if name.startswith("is_") or name.endswith("_flag"):
            return "integer"
    return "text"


def _databricks_columns(schema: str, table: str) -> list[tuple[str, str, bool]]:
    from src.utils.connection import get_databricks_connection

    conn = get_databricks_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(f"DESCRIBE banking_transactions_db.{schema}.{table}")
            rows = cur.fetchall()
        result = []
        for row in rows:
            name = getattr(row, "col_name", row[0])
            dtype = getattr(row, "data_type", row[1])
            if not name or str(name).startswith("#") or name in AUDIT_COLUMNS:
                continue
            result.append((name, dtype, True))
        return result
    finally:
        conn.close()


def _map_databricks(dtype: str, name: str) -> str:
    d = str(dtype).lower()
    if "int" in d:
        return "bigint"
    if d == "string":
        return "text"
    if d == "double":
        return "numeric(18,2)" if _is_money(name) else "double precision"
    if d == "date":
        return "date"
    if d == "timestamp":
        return "timestamptz"
    if d.startswith("decimal") or d == "numeric":
        return "numeric(18,2)"
    if d == "boolean":
        return "boolean"
    return "text"


def _columns_for(entry: dict[str, Any]) -> list[dict[str, Any]]:
    source = entry["source"]
    schema = entry["source_schema"]
    table = entry["source_table"]
    if source == "mysql_source":
        raw = _mysql_columns(schema, table)
        mapper = _map_mysql
    elif source == "mongodb_source":
        raw = _mongo_columns(schema, table)
        mapper = None
    elif source == "databricks_source":
        raw = _databricks_columns(schema, table)
        mapper = _map_databricks
    else:
        raise ValueError(f"unknown source {source!r}")

    business_keys = set(entry["business_key"])
    columns = []
    for name, dtype, nullable in raw:
        mapped = dtype if mapper is None else mapper(dtype, name)
        col = {
            "name": name,
            "type": mapped,
            "nullable": False if name in business_keys else nullable,
        }
        if name in business_keys:
            col["key"] = True
        columns.append(col)
    return columns


def _build_contract(entry: dict[str, Any]) -> dict[str, Any]:
    table = entry["target_table"]
    contract: dict[str, Any] = {
        "contract_version": 1,
        "name": table,
        "description": f"Auto-generated contract for {entry['source_table']}. Review before relying on it.",
        "source": entry["source"],
        "source_schema": entry["source_schema"],
        "source_table": entry["source_table"],
        "target_schema": entry["target_schema"],
        "target_table": table,
        "business_key": entry["business_key"],
        "load_strategy": entry["load_strategy"],
        "columns": _columns_for(entry),
        "quality": QUALITY,
        "owner": "banking-data-platform",
        "tags": ["auto-generated"],
    }
    if entry["load_strategy"] == "incremental":
        contract["incremental_column"] = entry["incremental_column"]
        contract["watermark_strategy"] = entry["watermark_strategy"]
        if entry.get("watermark_strategy") == "timestamp":
            contract["match_mode"] = "strict_gt"
    else:
        contract["incremental_column"] = None
        contract["watermark_strategy"] = None
    num_partitions = entry.get("num_partitions")
    if num_partitions:
        contract["num_partitions"] = num_partitions
    return contract


def _contract_path(entry: dict[str, Any]) -> Path:
    directory = SOURCE_TO_DIR[entry["source"]]
    return CONTRACTS_DIR / directory / f"{entry['target_table']}.json"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Sync contracts from the source registry."
    )
    parser.add_argument(
        "--update", action="store_true", help="regenerate existing contracts"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="print actions without writing"
    )
    args = parser.parse_args(argv)

    from contracts.validate import validate_contract

    registry = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    created = 0
    updated = 0
    skipped = 0
    for entry in registry["tables"]:
        path = _contract_path(entry)
        if path.exists() and not args.update:
            skipped += 1
            continue
        try:
            contract = _build_contract(entry)
            validate_contract(contract, path=str(path))
        except Exception as exc:  # noqa: BLE001 - report and continue
            logger.error("%s: %s", path, exc)
            continue
        action = "update" if path.exists() else "create"
        if args.dry_run:
            logger.info("[dry-run] %s: %s", action, path)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(contract, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        if action == "create":
            created += 1
        else:
            updated += 1
        logger.info("%s: %s", action, path)
    logger.info("done: created=%d updated=%d skipped=%d", created, updated, skipped)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
