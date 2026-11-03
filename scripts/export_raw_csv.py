"""scripts/export_raw_csv.py — snapshot registry source tables into data/raw/<source>/<table>.csv.gz.

Streams one full read per table (no watermark, no audit writes) so the repo can ship
the raw data as gzipped CSVs and a fresh clone can load them with scripts/load_raw_csv.py.

    python scripts/export_raw_csv.py                       # all three sources
    python scripts/export_raw_csv.py --sources mysql mongo
    python scripts/export_raw_csv.py --limit 1000          # quick sample
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import re
import sys
from collections.abc import Iterator
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import pymysql.cursors  # noqa: E402  (lazy driver, same as utils.connection)

from utils.config import require  # noqa: E402
from utils.connection import (  # noqa: E402
    dbx_call,
    get_databricks_connection,
    get_mongo_client,
    get_mysql_connection,
)
from utils.logger import get_logger  # noqa: E402

logger = get_logger("export_raw_csv")

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "contracts" / "registry.json"
FOLDER = {
    "mysql_source": "mysql",
    "mongodb_source": "mongo",
    "databricks_source": "databricks",
}
IDENT = re.compile(r"^[A-Za-z0-9_]+$")


def _cell(value: Any) -> Any:
    """One CSV cell; datetimes/decimals/ObjectIds become plain text."""
    if value is None:
        return ""
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return format(value, "f")
    return value


def _write(
    dest: Path, columns: list[str], rows: Iterator[list[Any]], limit: int | None
) -> int:
    """Stream rows to dest as gzip (temp file, renamed at the end); returns rows written."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    written = 0
    with gzip.open(tmp, "wt", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(columns)
        for row in rows:
            writer.writerow([_cell(v) for v in row])
            written += 1
            if limit is not None and written >= limit:
                break
    tmp.replace(dest)
    return written


def export_mysql(cfg: dict, dest: Path, limit: int | None) -> int:
    """SELECT * one table from MySQL through a streaming cursor."""
    with get_mysql_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(f"SELECT COUNT(*) FROM {cfg['source_table']}")
            logger.info("[%s] source rows: %s", cfg["source_table"], cur.fetchone()[0])
        with conn.cursor(pymysql.cursors.SSCursor) as cur:
            query = f"SELECT * FROM {cfg['source_table']}"
            if limit:
                query += f" LIMIT {limit}"
            cur.execute(query)
            columns = [d[0] for d in cur.description]
            return _write(dest, columns, cur.fetchall_unbuffered(), limit)


def export_mongo(cfg: dict, dest: Path, limit: int | None) -> int:
    """Iterate a collection in natural order; documents are flat in this project."""
    client = get_mongo_client()
    try:
        coll = client[require("MONGO_DB_NAME")][cfg["source_table"]]
        logger.info(
            "[%s] source docs: ~%s",
            cfg["source_table"],
            coll.estimated_document_count(),
        )
        cursor = coll.find({})
        first = next(cursor, None)
        if first is None:
            return _write(dest, [], iter([]), limit)
        columns = sorted(first)

        def rows() -> Iterator[list[Any]]:
            yield [first[k] for k in columns]
            for doc in cursor:
                if sorted(doc) != columns:
                    raise RuntimeError(
                        f"{cfg['source_table']}: document schema drift mid-export, "
                        f"expected {columns}, got {sorted(doc)}"
                    )
                yield [doc[k] for k in columns]

        return _write(dest, columns, rows(), limit)
    finally:
        client.close()


def export_databricks(cfg: dict, dest: Path, limit: int | None) -> int:
    """SELECT * through the Databricks SQL connector in fetch batches."""
    table = f"{cfg['source_schema']}.{cfg['source_table']}"
    if not IDENT.match(cfg["source_table"]) or not IDENT.match(cfg["source_schema"]):
        raise RuntimeError(f"unsafe identifier: {table}")
    conn = get_databricks_connection()
    try:
        cur = conn.cursor()
        query = f"SELECT * FROM {table}"
        if limit:
            query += f" LIMIT {limit}"
        dbx_call(f"export {table}", lambda: cur.execute(query))
        columns = [d[0] for d in cur.description]

        def rows() -> Iterator[list[Any]]:
            while True:
                batch = dbx_call(f"fetch {table}", lambda: cur.fetchmany(10_000))
                if not batch:
                    return
                for row in batch:
                    yield list(row)

        return _write(dest, columns, rows(), limit)
    finally:
        conn.close()


EXPORTERS = {
    "mysql_source": export_mysql,
    "mongodb_source": export_mongo,
    "databricks_source": export_databricks,
}


def load_registry(sources: set[str]) -> list[dict]:
    tables = json.loads(REGISTRY.read_text(encoding="utf-8"))["tables"]
    return [t for t in tables if t["source"] in sources]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Export registry sources to data/raw CSVs."
    )
    parser.add_argument(
        "--sources",
        nargs="+",
        choices=sorted(FOLDER.values()),
        default=sorted(FOLDER.values()),
        help="source folders to export (default: all)",
    )
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data" / "raw")
    parser.add_argument(
        "--limit", type=int, default=None, help="rows per table (default: full)"
    )
    args = parser.parse_args(argv)

    wanted = {folder for folder, name in FOLDER.items() if name in args.sources}
    ok = True
    for cfg in load_registry(wanted):
        dest = args.data_dir / FOLDER[cfg["source"]] / f"{cfg['target_table']}.csv.gz"
        try:
            rows = EXPORTERS[cfg["source"]](cfg, dest, args.limit)
        except Exception:
            logger.exception("[%s] export failed", cfg["target_table"])
            ok = False
            continue
        logger.info("[%s] -> %s (%s rows)", cfg["target_table"], dest, rows)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
