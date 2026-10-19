"""scripts/seed_watermarks.py — bootstrap audit.etl_watermarks for newly-incremental tables.

Sets last_watermark_value to the current MAX at the source, so the first
incremental extract picks up only rows newer than today's data instead of
re-landing the whole collection/table as raw duplicates. Never rewinds an
existing watermark unless --force is passed. Run AFTER switching a table to
load_strategy='incremental' (sql/scripts/05_*.sql) and BEFORE the next extract.

    python scripts/seed_watermarks.py                  # mongo + databricks tables
    python scripts/seed_watermarks.py --dry-run        # show what would be seeded
    python scripts/seed_watermarks.py --force          # overwrite existing watermarks
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from utils.audit import get_enabled_tables, seed_watermark  # noqa: E402
from utils.logger import get_logger  # noqa: E402
from utils.spark_io import databricks_max_watermark, mongo_max_watermark  # noqa: E402

logger = get_logger("seed_watermarks")

# mysql_source is absent on purpose: it stays on full loads.
MAX_WATERMARK = {
    "mongodb_source": mongo_max_watermark,
    "databricks_source": databricks_max_watermark,
}


def seed_source(source_name: str, *, force: bool, dry_run: bool) -> bool:
    """Seed every enabled incremental table of one source; False if any table failed."""
    ok = True
    for cfg in get_enabled_tables(source_name):
        table = f"{cfg['source_schema']}.{cfg['source_table']}"
        if cfg["load_strategy"] != "incremental":
            logger.info("[%s] %s: full load, nothing to seed", source_name, table)
            continue
        try:
            value = MAX_WATERMARK[source_name](cfg)
        except Exception:
            logger.exception("[%s] %s: could not read source MAX", source_name, table)
            ok = False
            continue
        if value is None:
            logger.warning(
                "[%s] %s: source is empty, watermark not seeded", source_name, table
            )
            continue
        if dry_run:
            logger.info(
                "[%s] %s: would seed %s='%s'",
                source_name,
                table,
                cfg["incremental_column"],
                value,
            )
            continue
        if seed_watermark(cfg, value, force=force):
            logger.info(
                "[%s] %s: seeded %s='%s'",
                source_name,
                table,
                cfg["incremental_column"],
                value,
            )
        else:
            logger.info(
                "[%s] %s: watermark already set (use --force to overwrite)",
                source_name,
                table,
            )
    return ok


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Seed source MAX into audit.etl_watermarks."
    )
    parser.add_argument(
        "--sources",
        nargs="+",
        choices=sorted(MAX_WATERMARK),
        default=sorted(MAX_WATERMARK),
        help="sources to seed (default: mongodb_source and databricks_source)",
    )
    parser.add_argument(
        "--force", action="store_true", help="overwrite an existing watermark"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="log the values without writing"
    )
    args = parser.parse_args(argv)

    ok = all(
        seed_source(name, force=args.force, dry_run=args.dry_run)
        for name in args.sources
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
