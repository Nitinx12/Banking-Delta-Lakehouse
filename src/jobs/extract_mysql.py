"""MySQL to PostgreSQL raw schema. Usage: python src/jobs/extract_mysql.py [--tables a b] [--parallel N] [--finalize]"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from utils.extract_runner import Prepared, Source, TableContext, run_source
from utils.spark_io import (
    add_audit_columns,
    mysql_column_types,
    mysql_count,
    mysql_max_watermark,
    read_mysql,
)


def prepare(ctx: TableContext) -> Prepared:
    column_types = mysql_column_types(ctx.cfg)
    df = add_audit_columns(
        read_mysql(ctx.spark, ctx.cfg, ctx.start, ctx.end), ctx.run.table_run_id
    )
    return Prepared(df, {"column_types": column_types})


SOURCE = Source(
    name="mysql_source",
    app="extract_mysql",
    spark_sources=("mysql", "postgres"),
    max_watermark=mysql_max_watermark,
    count=mysql_count,
    prepare=prepare,
    empty_message="table is empty or '{column}' is all NULL",
)


def main(argv: list[str] | None = None) -> int:
    return run_source(SOURCE, argv)


if __name__ == "__main__":
    sys.exit(main())
