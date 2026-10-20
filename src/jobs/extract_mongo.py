"""MongoDB to PostgreSQL raw schema. Usage: python src/jobs/extract_mongo.py [--tables a b] [--parallel N] [--finalize]"""

from __future__ import annotations

import sys
from pathlib import Path

from pyspark import StorageLevel

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from utils.audit import log_dq_result
from utils.extract_runner import Prepared, Source, TableContext, run_source
from utils.spark_io import (
    add_audit_columns,
    cast_integers,
    cast_temporal,
    mongo_count,
    mongo_max_watermark,
    prepare_for_jdbc,
    read_mongo,
    temporal_parse_failures,
)

FOREIGN_KEYS: dict[str, tuple[str, ...]] = {
    "support_tickets": ("customer_id",),
    "card_transactions": ("card_id",),
}


def prepare(ctx: TableContext) -> Prepared:
    cfg = ctx.cfg
    raw = read_mongo(ctx.spark, cfg, ctx.start, ctx.end)
    df, temporal_cols = cast_temporal(raw)
    if temporal_cols:
        raw.persist(StorageLevel.MEMORY_AND_DISK)
    df = cast_integers(df, FOREIGN_KEYS.get(cfg["source_table"], ()))
    if temporal_cols:
        ctx.logger.info(
            "[%s] text date fields cast: %s",
            ctx.label,
            ", ".join(f"{c}->{k}" for c, k in temporal_cols.items()),
        )
    df, json_cols = prepare_for_jdbc(df)
    df = add_audit_columns(df, ctx.run.table_run_id)
    if json_cols:
        ctx.logger.info(
            "[%s] nested fields stored as jsonb: %s", ctx.label, ", ".join(json_cols)
        )

    def check_temporal(expected: int) -> None:
        try:
            counts = temporal_parse_failures(raw, temporal_cols)
        finally:
            raw.unpersist()
        failures = {col: n for col, n in counts.items() if n}
        if not failures:
            return
        total = sum(failures.values())
        ctx.logger.warning(
            "[%s] %s date value(s) did not parse and were set to NULL: %s",
            ctx.label,
            total,
            failures,
        )
        log_dq_result(
            check_name="temporal_values_parsed",
            status="WARNING",
            records_checked=expected * len(temporal_cols),
            records_failed=total,
            details={"columns": failures},
            pipeline_run_id=ctx.pipeline_run_id,
            table_run_id=ctx.run.table_run_id,
            config_id=cfg["config_id"],
        )

    return Prepared(
        df, {"jsonb_columns": json_cols}, check_temporal if temporal_cols else None
    )


SOURCE = Source(
    name="mongodb_source",
    app="extract_mongo",
    spark_sources=("mongodb", "postgres"),
    max_watermark=mongo_max_watermark,
    count=mongo_count,
    prepare=prepare,
    empty_message="no documents with a value in '{column}'",
)


def main(argv: list[str] | None = None) -> int:
    return run_source(SOURCE, argv)


if __name__ == "__main__":
    sys.exit(main())
