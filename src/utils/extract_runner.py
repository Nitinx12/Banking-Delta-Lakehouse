"""Shared runner for the extract scripts: batch window, load, promote, watermark, data quality, parallel tables."""

from __future__ import annotations

import argparse
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

from .audit import (
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
from .logger import get_logger
from .session import get_spark_session, pg_transaction, stop_spark
from .spark_io import drop_staging, promote_staging, write_staging


@dataclass
class TableContext:
    spark: Any
    pipeline_run_id: Any
    cfg: dict
    start: Optional[str]
    end: Optional[str]
    run: Any
    label: str
    logger: Any


@dataclass
class Prepared:
    df: Any
    promote_kwargs: dict[str, Any] = field(default_factory=dict)
    after_dq: Optional[Callable[[int], None]] = None


@dataclass(frozen=True)
class Source:
    name: str
    app: str
    spark_sources: tuple[str, ...]
    max_watermark: Callable[[dict], Any]
    count: Callable[[dict, Any, Any], int]
    prepare: Callable[[TableContext], Prepared]
    empty_message: str = "no rows with a value in '{column}'"
    max_workers: Optional[int] = (
        None  # None -> honour --parallel; set to 1 for sources that can't run concurrently
    )


def _independent_connections() -> bool:
    try:
        with pg_transaction() as first, pg_transaction() as second:
            return first is not second
    except Exception:  # noqa: BLE001 - cannot prove isolation, so stay sequential
        return False


class Extractor:
    def __init__(self, source: Source) -> None:
        self.source = source
        self.logger = get_logger(source.app)

    def extract_table(
        self,
        spark,
        pipeline_run_id,
        cfg: dict,
        task_id: Optional[str],
        try_number: Optional[int],
    ) -> str:
        source = self.source
        log = self.logger
        incremental = cfg["load_strategy"] == "incremental"
        label = f"{cfg['source_schema']}.{cfg['source_table']}"

        with table_run(
            pipeline_run_id, cfg, airflow_task_id=task_id, airflow_try_number=try_number
        ) as run:
            start = end = lock_version = None

            if incremental:
                wm = get_watermark(cfg["config_id"])
                start = wm["last_watermark_value"] if wm else None
                end = source.max_watermark(cfg)
                if end is None:
                    run.skip(
                        source.empty_message.format(column=cfg["incremental_column"])
                    )
                    return "SKIPPED"
                if start is not None and end == start:
                    run.skip("no new data past the watermark")
                    return "SKIPPED"
                lock_version = begin_batch(cfg, start, end)["lock_version"]
                run.watermark_start, run.watermark_end = start, end
                log.info(
                    "[%s] incremental window: %s -> %s",
                    label,
                    start or "(beginning)",
                    end,
                )
            else:
                log.info("[%s] full load", label)

            prepared = source.prepare(
                TableContext(spark, pipeline_run_id, cfg, start, end, run, label, log)
            )
            run.rows_extracted = write_staging(prepared.df, cfg)

            with pg_transaction() as conn:
                run.rows_landed = promote_staging(conn, cfg, **prepared.promote_kwargs)
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

            expected = source.count(cfg, start, end)
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
                log.warning(
                    "[%s] row count differs: source=%s landed=%s (live source changed during the run?)",
                    label,
                    expected,
                    run.rows_landed,
                )
            if prepared.after_dq is not None:
                prepared.after_dq(expected)
            return "SUCCESS"

    def run(self, argv: Optional[list[str]] = None) -> int:
        source = self.source
        log = self.logger
        parser = argparse.ArgumentParser(
            description=f"Extract {source.name} tables into the Postgres raw schema."
        )
        parser.add_argument("--tables", nargs="*", help="only these source_table names")
        parser.add_argument(
            "--finalize",
            action="store_true",
            help="close the pipeline run when done (standalone runs always do)",
        )
        parser.add_argument(
            "--parallel",
            type=int,
            default=int(os.environ.get("EXTRACT_PARALLEL", "3")),
            help="number of tables extracted at the same time",
        )
        parser.add_argument("--dag-id", default=os.environ.get("AIRFLOW_CTX_DAG_ID"))
        parser.add_argument(
            "--dag-run-id", default=os.environ.get("AIRFLOW_CTX_DAG_RUN_ID")
        )
        args = parser.parse_args(argv)
        if args.parallel < 1:
            parser.error("--parallel must be 1 or more")

        task_id = os.environ.get("AIRFLOW_CTX_TASK_ID")
        try_number = (
            int(os.environ["AIRFLOW_CTX_TRY_NUMBER"])
            if os.environ.get("AIRFLOW_CTX_TRY_NUMBER")
            else None
        )

        fail_stale_runs(max_age_hours=6)
        pipeline_run_id = start_pipeline_run(
            dag_id=args.dag_id,
            dag_run_id=args.dag_run_id,
            trigger_type="airflow" if args.dag_run_id else "manual",
        )

        configs = get_enabled_tables(source.name)
        if args.tables:
            wanted = set(args.tables)
            configs = [c for c in configs if c["source_table"] in wanted]
            missing = wanted - {c["source_table"] for c in configs}
            if missing:
                log.warning(
                    "Not registered / not enabled in audit.source_tables: %s",
                    sorted(missing),
                )
        if not configs:
            log.warning("Nothing to extract for %s", source.name)

        results: dict[str, str] = {}
        try:
            if configs:
                workers = min(args.parallel, len(configs))
                if source.max_workers is not None:
                    workers = min(workers, source.max_workers)
                if workers > 1 and not _independent_connections():
                    log.warning(
                        "pg_transaction shares one connection, running tables one at a time"
                    )
                    workers = 1
                spark = get_spark_session(source.app, sources=source.spark_sources)
                log.info("extracting %d table(s), %d at a time", len(configs), workers)
                with ThreadPoolExecutor(max_workers=workers) as pool:
                    futures = {
                        pool.submit(
                            self.extract_table,
                            spark,
                            pipeline_run_id,
                            cfg,
                            task_id,
                            try_number,
                        ): cfg["source_table"]
                        for cfg in configs
                    }
                    for future in as_completed(futures):
                        table = futures[future]
                        try:
                            results[table] = future.result()
                        except Exception:  # noqa: BLE001 - already recorded in audit by table_run
                            results[table] = "FAILED"
        finally:
            stop_spark()
            if args.finalize or not args.dag_run_id:
                finish_pipeline_run(pipeline_run_id)

        log.info("Done: %s", results)
        return 1 if "FAILED" in results.values() else 0


def run_source(source: Source, argv: Optional[list[str]] = None) -> int:
    return Extractor(source).run(argv)
