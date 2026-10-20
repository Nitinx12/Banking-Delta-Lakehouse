"""Databricks to PostgreSQL raw schema. Usage: python src/jobs/extract_databricks.py [--tables a b] [--parallel N] [--finalize]"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from utils.extract_runner import Prepared, Source, TableContext, run_source
from utils.spark_io import (
    add_audit_columns,
    databricks_count,
    databricks_max_watermark,
    prepare_for_jdbc,
    read_databricks,
)


def prepare(ctx: TableContext) -> Prepared:
    df = read_databricks(ctx.spark, ctx.cfg, ctx.start, ctx.end)
    df, json_cols = prepare_for_jdbc(df)
    df = add_audit_columns(df, ctx.run.table_run_id)
    if json_cols:
        ctx.logger.info(
            "[%s] nested fields stored as jsonb: %s", ctx.label, ", ".join(json_cols)
        )
    return Prepared(df, {"jsonb_columns": json_cols})


SOURCE = Source(
    name="databricks_source",
    app="extract_databricks",
    spark_sources=("postgres",),
    max_watermark=databricks_max_watermark,
    count=databricks_count,
    prepare=prepare,
)


def main(argv: list[str] | None = None) -> int:
    return run_source(SOURCE, argv)


if __name__ == "__main__":
    sys.exit(main())
