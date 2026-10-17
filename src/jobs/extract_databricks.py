"""extract_databricks.py — Databricks `public`  ->  PostgreSQL `raw` schema (PySpark).

Run from the project root (the folder that contains utils/):

    python extract_databricks.py                       # every enabled databricks_source table
    python extract_databricks.py --tables loans        # only these tables
    python extract_databricks.py --finalize            # also close the pipeline run (last task of a DAG)

What lands in Postgres
----------------------
* table name  = audit.source_tables.target_table  (register it equal to the Databricks table name)
* column name = Databricks column name, column type = the native Spark equivalent:
      bigint -> bigint     int -> integer     double -> double precision    date -> date
      timestamp -> timestamp     string -> text     boolean -> boolean     decimal(p,s) -> numeric(p,s)
* complex columns (struct/array/map) become jsonb under the SAME name
* two extra metadata columns:  _batch_id (table_run_id)  and  _loaded_at

Read path: the SQL warehouse is queried with the pure-Python connector and results are
streamed to local Parquet, which Spark reads (no JDBC driver needed for Databricks).
Per table:  window snapshot -> Parquet -> staging table -> ONE transaction
            (staging -> raw table + watermark advance) -> row-count data-quality check.
Everything is recorded in the audit.* tables.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from utils.audit import (
    advance_watermark,
    begin_batch,
    fail_stale_runs,
    finish_pipeline_run,
    get_enabled_tables,
    get_watermark,
    log_dq_result,
    start_pipeline_run,
    table_run,
)
from utils.logger import get_logger
from utils.session import get_spark_session, pg_transaction, stop_spark
from utils.spark_io import (
    add_audit_columns,
    databricks_count,
    databricks_max_watermark,
    drop_staging,
    prepare_for_jdbc,
    promote_staging,
    read_databricks,
    write_staging,
)

logger = get_logger("extract_databricks")

SOURCE_NAME = "databricks_source"


def extract_table(
    spark, pipeline_run_id, cfg: dict, task_id: str | None, try_number: int | None
) -> str:
    """Extract ONE table. Returns the final status (SUCCESS / SKIPPED). Raises on failure."""
    incremental = cfg["load_strategy"] == "incremental"
    label = f"{cfg['source_schema']}.{cfg['source_table']}"

    with table_run(
        pipeline_run_id, cfg, airflow_task_id=task_id, airflow_try_number=try_number
    ) as run:
        start = end = None
        lock_version = None

        # ---- 1. decide the batch window (incremental only) -----------------------------
        if incremental:
            wm = get_watermark(cfg["config_id"])
            start = wm["last_watermark_value"] if wm else None
            end = databricks_max_watermark(
                cfg
            )  # snapshot upper bound, read straight from Databricks
            if end is None:
                run.skip(f"no rows with a value in '{cfg['incremental_column']}'")
                return "SKIPPED"
            if start is not None and end == start:
                run.skip("no new data past the watermark")
                return "SKIPPED"
            lock_version = begin_batch(cfg, start, end)["lock_version"]
            run.watermark_start, run.watermark_end = start, end
            logger.info(
                "[%s] incremental window: %s -> %s", label, start or "(beginning)", end
            )
        else:
            logger.info("[%s] full load", label)

        # ---- 2. read from Databricks, make it JDBC-writable, add lineage columns -------
        df = read_databricks(spark, cfg, start, end)
        df, json_cols = prepare_for_jdbc(df)
        df = add_audit_columns(df, run.table_run_id)
        if json_cols:
            logger.info(
                "[%s] nested fields stored as jsonb: %s", label, ", ".join(json_cols)
            )

        # ---- 3. Spark -> staging table (parallel JDBC) --------------------------------
        run.rows_extracted = write_staging(df, cfg)

        # ---- 4. ONE transaction: staging -> raw table AND watermark --------------------
        with pg_transaction() as conn:
            run.rows_landed = promote_staging(conn, cfg, jsonb_columns=json_cols)
            if incremental:
                advance_watermark(
                    cfg["config_id"],
                    end,
                    expected_lock_version=lock_version,
                    table_run_id=run.table_run_id,
                    pipeline_run_id=pipeline_run_id,
                    conn=conn,
                )
        drop_staging(cfg)

        # ---- 5. data-quality: source count vs landed (logged, never blocks) ------------
        expected = databricks_count(cfg, start, end)
        matches = expected == run.rows_landed
        log_dq_result(
            check_name="row_count_source_vs_landed",
            status="PASSED" if matches else "WARNING",
            records_checked=expected,
            records_failed=abs(expected - run.rows_landed),
            details={
                "source_count": expected,
                "landed": run.rows_landed,
                "window": [start, end],
            },
            pipeline_run_id=pipeline_run_id,
            table_run_id=run.table_run_id,
            config_id=cfg["config_id"],
        )
        if not matches:
            logger.warning(
                "[%s] row count differs: source=%s landed=%s (live table changed during the run?)",
                label,
                expected,
                run.rows_landed,
            )
        return "SUCCESS"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Extract Databricks tables into the Postgres raw schema."
    )
    parser.add_argument("--tables", nargs="*", help="only these source_table names")
    parser.add_argument(
        "--finalize",
        action="store_true",
        help="close the pipeline run when done (standalone runs always do)",
    )
    parser.add_argument("--dag-id", default=os.environ.get("AIRFLOW_CTX_DAG_ID"))
    parser.add_argument(
        "--dag-run-id", default=os.environ.get("AIRFLOW_CTX_DAG_RUN_ID")
    )
    args = parser.parse_args(argv)

    task_id = os.environ.get("AIRFLOW_CTX_TASK_ID")
    try_number = (
        int(os.environ["AIRFLOW_CTX_TRY_NUMBER"])
        if os.environ.get("AIRFLOW_CTX_TRY_NUMBER")
        else None
    )

    fail_stale_runs(
        max_age_hours=6
    )  # clean up runs killed earlier (OOM, power loss ...)
    pipeline_run_id = start_pipeline_run(
        dag_id=args.dag_id,
        dag_run_id=args.dag_run_id,
        trigger_type="airflow" if args.dag_run_id else "manual",
    )

    configs = get_enabled_tables(SOURCE_NAME)
    if args.tables:
        wanted = set(args.tables)
        configs = [c for c in configs if c["source_table"] in wanted]
        missing = wanted - {c["source_table"] for c in configs}
        if missing:
            logger.warning(
                "Not registered / not enabled in audit.source_tables: %s",
                sorted(missing),
            )
    if not configs:
        logger.warning("Nothing to extract for %s", SOURCE_NAME)

    failed, results = 0, {}
    spark = None
    try:
        if configs:
            spark = get_spark_session("extract_databricks", sources=("postgres",))
        for cfg in configs:
            try:
                results[cfg["source_table"]] = extract_table(
                    spark, pipeline_run_id, cfg, task_id, try_number
                )
            except Exception:  # already recorded in audit.* by table_run(); keep going with the next table
                results[cfg["source_table"]] = "FAILED"
                failed += 1
    finally:
        stop_spark()
        if args.finalize or not args.dag_run_id:
            finish_pipeline_run(pipeline_run_id)

    logger.info("Done: %s", results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
