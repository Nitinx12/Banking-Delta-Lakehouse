"""scripts/load_raw_csv.py — land the data/raw CSV snapshots into the raw schema.

Meant for a fresh clone that has no source-system access: the repo ships gzipped
CSVs under data/raw/<source>/<table>.csv.gz, this script creates any missing raw
table from contracts/<source>/<table>.json, then TRUNCATE + COPY the file inside
one transaction per table. Running it twice replaces the same snapshot, so it is
always idempotent.

    python scripts/load_raw_csv.py                       # every table with a CSV
    python scripts/load_raw_csv.py --tables accounts     # one table
    python scripts/load_raw_csv.py --dry-run             # show the plan only
"""

from __future__ import annotations

import argparse
import io
import json
import re
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import polars as pl  # noqa: E402

from utils.config import require  # noqa: E402
from utils.connection import get_pg_connection  # noqa: E402
from utils.logger import get_logger  # noqa: E402

logger = get_logger("load_raw_csv")

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "contracts" / "registry.json"
CONTRACTS = ROOT / "contracts"
# registry source -> (data/raw folder, contracts folder)
SOURCE_FOLDERS = {
    "mysql_source": ("mysql", "mysql"),
    "mongodb_source": ("mongo", "mongodb"),
    "databricks_source": ("databricks", "databricks"),
}
META_COLUMNS = ("_batch_id", "_loaded_at")
IDENT = re.compile(r"^[A-Za-z0-9_]+$")
PG_TYPE = re.compile(r"^[a-z][a-z ]*(\(\d+(,\d+)?\))?$")
DEFAULT_BATCH_ROWS = 50_000


def registry_tables() -> list[dict]:
    """Every source table the project knows, in registry order."""
    return json.loads(REGISTRY.read_text(encoding="utf-8"))["tables"]


def contract_for(cfg: dict) -> dict:
    """Column contract for one registry entry (the project's schema source of truth)."""
    _, folder = SOURCE_FOLDERS[cfg["source"]]
    path = CONTRACTS / folder / f"{cfg['target_table']}.json"
    return json.loads(path.read_text(encoding="utf-8"))


def data_file(data_dir: Path, cfg: dict) -> Path | None:
    """The snapshot for one table; a fresh export (.csv) wins over the shipped .csv.gz."""
    folder, _ = SOURCE_FOLDERS[cfg["source"]]
    stem = data_dir / folder / cfg["target_table"]
    for suffix in (".csv", ".csv.gz"):
        if stem.with_name(stem.name + suffix).is_file():
            return stem.with_name(stem.name + suffix)
    return None


def create_table_sql(schema: str, contract: dict) -> str:
    """CREATE TABLE from the contract, plus the raw metadata contract columns."""
    table = contract["target_table"]
    if not IDENT.match(table) or not IDENT.match(schema):
        raise ValueError(f"unsafe identifier: {schema}.{table}")
    parts = []
    for col in contract["columns"]:
        name, coltype = col["name"], col["type"]
        if not IDENT.match(name) or not PG_TYPE.fullmatch(coltype):
            raise ValueError(f"unsafe column definition: {name} {coltype}")
        null = "" if col.get("nullable", True) else " NOT NULL"
        parts.append(f'"{name}" {coltype}{null}')
    parts.append('"_batch_id" text NOT NULL')
    parts.append('"_loaded_at" timestamptz NOT NULL')
    return f'CREATE TABLE IF NOT EXISTS {schema}."{table}" ({", ".join(parts)})'


def select_columns(
    header: list[str],
    target: dict[str, bool] | None,
    contract: dict,
) -> list[str]:
    """Columns to COPY, contract order first; target maps column -> NOT NULL.

    target=None means the table is created here, so only contract columns that
    exist in the CSV are copied (a missing NOT NULL contract column is an error).
    """
    ccols = [c["name"] for c in contract["columns"]]
    required = {c["name"] for c in contract["columns"] if not c.get("nullable", True)}
    if target is None:
        missing = [c for c in ccols if c not in header and c in required]
        if missing:
            raise ValueError(f"CSV is missing required columns: {missing}")
        picked = [c for c in ccols if c in header]
    else:
        missing = [c for c in ccols if c not in header and target.get(c, False)]
        if missing:
            raise ValueError(f"CSV is missing required columns: {missing}")
        picked = [c for c in ccols if c in target and c in header] + [
            c for c in header if c in target and c not in ccols
        ]
    return picked + list(META_COLUMNS)


def copy_batches(
    conn,
    schema: str,
    table: str,
    columns: list[str],
    path: Path,
    batch_rows: int,
) -> int:
    """Stream the CSV into an empty table in batches of strings (no re-typing)."""
    header = pl.read_csv(path, n_rows=0).columns
    overrides = {c: pl.String for c in header}
    quote = ", ".join(f'"{c}"' for c in columns)
    copy_sql = f'COPY {schema}."{table}" ({quote}) FROM STDIN WITH (FORMAT CSV)'
    batch_id, loaded_at = str(uuid.uuid4()), datetime.now(UTC).isoformat()
    offset = rows = 0
    with conn.cursor() as cur:
        while True:
            df = pl.read_csv(
                path,
                n_rows=batch_rows,
                skip_rows_after_header=offset,
                schema_overrides=overrides,
            )
            if df.height == 0:
                return rows
            data_cols = [c for c in columns if c in header]
            batch = df.select(data_cols).with_columns(
                pl.lit(batch_id).alias("_batch_id"),
                pl.lit(loaded_at).alias("_loaded_at"),
            )
            cur.copy_expert(
                copy_sql, io.StringIO(batch.write_csv(include_header=False))
            )
            rows += batch.height
            offset += batch.height
            if batch.height < batch_rows:
                return rows


def target_columns(conn, schema: str, table: str) -> dict[str, bool]:
    """Existing target columns as {name: NOT NULL}; empty when the table is missing."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT column_name, is_nullable = 'NO'
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
            ORDER BY ordinal_position
            """,
            (schema, table),
        )
        return dict(cur.fetchall())


def ensure_columns(
    conn, schema: str, table: str, header: list[str], contract: dict
) -> None:
    """Add CSV/contract columns (and the metadata pair) the target is still missing."""
    types = {c["name"]: c["type"] for c in contract["columns"]}
    types["_batch_id"], types["_loaded_at"] = "text", "timestamptz"
    target = target_columns(conn, schema, table)
    for name in header + list(META_COLUMNS):
        if name in target:
            continue
        coltype = types.get(
            name, "text"
        )  # unknown CSV column lands as text, never float
        if not IDENT.match(name) or not PG_TYPE.fullmatch(coltype):
            raise ValueError(f"unsafe column definition: {name} {coltype}")
        with conn.cursor() as cur:
            cur.execute(f'ALTER TABLE {schema}."{table}" ADD COLUMN "{name}" {coltype}')
        logger.info("[%s] added column %s %s", table, name, coltype)


def load_table(conn, cfg: dict, path: Path, batch_rows: int) -> int:
    """Create if needed, add drifted columns, TRUNCATE, COPY — one transaction, safe to re-run."""
    schema, table = cfg["target_schema"], cfg["target_table"]
    contract = contract_for(cfg)
    header = pl.read_csv(path, n_rows=0).columns
    with conn:
        if not target_columns(conn, schema, table):
            with conn.cursor() as cur:
                cur.execute(create_table_sql(schema, contract))
            logger.info("[%s] created %s.%s from contract", table, schema, table)
        ensure_columns(conn, schema, table, header, contract)
        target = target_columns(conn, schema, table)
        with conn.cursor() as cur:
            cur.execute(f'TRUNCATE TABLE {schema}."{table}"')
        columns = select_columns(header, target, contract)
        rows = copy_batches(conn, schema, table, columns, path, batch_rows)
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Load data/raw CSV snapshots into the raw schema (polars + COPY)."
    )
    parser.add_argument(
        "--tables",
        nargs="+",
        default=None,
        help="target tables only (default: all with a CSV)",
    )
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data" / "raw")
    parser.add_argument("--batch-rows", type=int, default=DEFAULT_BATCH_ROWS)
    parser.add_argument(
        "--dry-run", action="store_true", help="list the plan, write nothing"
    )
    args = parser.parse_args(argv)
    batch_rows = max(1, args.batch_rows)

    plan = []
    for cfg in registry_tables():
        if args.tables and cfg["target_table"] not in args.tables:
            continue
        path = data_file(args.data_dir, cfg)
        if path is None:
            if args.tables:
                logger.error("[%s] no CSV under %s", cfg["target_table"], args.data_dir)
                return 1
            continue
        plan.append((cfg, path))
    if not plan:
        logger.error("no CSVs found under %s", args.data_dir)
        return 1

    if args.dry_run:
        for cfg, path in plan:
            cols = len(contract_for(cfg)["columns"])
            logger.info(
                "[%s] %s -> %s.%s (%s contract columns, replace snapshot)",
                cfg["target_table"],
                path,
                cfg["target_schema"],
                cfg["target_table"],
                cols,
            )
        return 0

    logger.info(
        "loading %s table(s) into %s@%s (schema raw)",
        len(plan),
        require("PG_DB"),
        require("PG_HOST"),
    )
    conn = get_pg_connection("load-raw-csv")
    ok = True
    try:
        with conn.cursor() as cur:
            cur.execute("CREATE SCHEMA IF NOT EXISTS raw")
        conn.commit()
        for cfg, path in plan:
            try:
                rows = load_table(conn, cfg, path, batch_rows)
            except Exception:
                conn.rollback()
                logger.exception("[%s] load failed", cfg["target_table"])
                ok = False
                continue
            logger.info("[%s] <- %s (%s rows)", cfg["target_table"], path, rows)
    finally:
        conn.close()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
