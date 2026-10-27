"""Audit-table helpers: run tracking, errors, watermarks, data quality.

All audit writes use plain psycopg2 (never Spark) and — unless you pass `conn=` —
their OWN short transaction. So "table run FAILED" is recorded even when the data
load's transaction rolled back.

Typical flow inside one table's extraction (see spark_io.py for the Spark parts):

    pipeline_run_id = start_pipeline_run(dag_id=..., dag_run_id=...)
    for cfg in get_enabled_tables("mysql_source"):
        with table_run(pipeline_run_id, cfg) as run:
            wm = begin_batch(cfg, start, end)          # snapshot the batch window
            ... Spark: source -> staging table ...
            with pg_transaction() as conn:             # ONE atomic transaction:
                run.rows_landed = promote_staging(conn, ...)      # data
                advance_watermark(cfg["config_id"], end,          # watermark
                                  expected_lock_version=wm["lock_version"],
                                  table_run_id=run.table_run_id,
                                  pipeline_run_id=pipeline_run_id, conn=conn)
    finish_pipeline_run(pipeline_run_id)
"""

from __future__ import annotations

import re
import traceback
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Any

import psycopg2.extras

from .logger import get_logger
from .session import pg_transaction

psycopg2.extras.register_uuid()
logger = get_logger(__name__)

Json = psycopg2.extras.Json


class WatermarkConflict(RuntimeError):
    """Another run advanced this table's watermark first (optimistic-lock failure)."""


# ------------------------------------------------------------------ plumbing
def _q(conn, sql: str, params: tuple | None = None, fetch: str | None = None):
    """Run SQL on `conn`, or in its own transaction when conn is None.

    fetch: None -> rowcount | "one" -> dict | "all" -> list[dict]
    """
    if conn is None:
        with pg_transaction() as own:
            return _q(own, sql, params, fetch)
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql, params)
        if fetch == "one":
            return cur.fetchone()
        if fetch == "all":
            return cur.fetchall()
        return cur.rowcount


_SECRET_RE = re.compile(
    r"(?i)(password|pwd|token|secret)=([^&;\s]+)|(://[^:/\s]+:)([^@\s]+)@"
)


def _redact(text: str) -> str:
    return _SECRET_RE.sub(
        lambda m: f"{m.group(1)}=***" if m.group(1) else f"{m.group(3)}***@", text
    )


def _classify(exc: BaseException) -> tuple[str, bool]:
    """(error_category, is_recoverable) from the exception type — cheap and dependency-free."""
    names = {c.__name__ for c in type(exc).__mro__}
    if isinstance(exc, WatermarkConflict):
        return "CONCURRENCY", False
    if names & {
        "OperationalError",
        "InterfaceError",
        "ConnectionError",
        "ServerSelectionTimeoutError",
        "TimeoutError",
    }:
        return "CONNECTION", True
    if names & {"Py4JJavaError", "Py4JError", "AnalysisException", "PythonException"}:
        return "SPARK", False
    if names & {"IntegrityError", "DataError", "ProgrammingError"}:
        return "DATA", False
    return "UNKNOWN", False


# ------------------------------------------------------------- pipeline runs
def start_pipeline_run(
    *,
    dag_id: str | None = None,
    dag_run_id: str | None = None,
    execution_date=None,
    run_type: str = "scheduled",
    trigger_type: str = "manual",
    conn=None,
) -> uuid.UUID:
    """Create (or re-attach to) the pipeline run of this DAG run.

    Parallel per-source Airflow tasks that pass the same (dag_id, dag_run_id)
    share ONE pipeline_run row.
    """
    row = _q(
        conn,
        """
        INSERT INTO audit.pipeline_runs
            (pipeline_run_id, dag_id, dag_run_id, execution_date, run_type, trigger_type)
        VALUES (%s, %s, %s, %s, %s, %s)
        ON CONFLICT (dag_id, dag_run_id) WHERE dag_run_id IS NOT NULL
        DO UPDATE SET status = 'RUNNING', ended_at = NULL, duration_seconds = NULL
        RETURNING pipeline_run_id
        """,
        (uuid.uuid4(), dag_id, dag_run_id, execution_date, run_type, trigger_type),
        fetch="one",
    )
    run_id = row["pipeline_run_id"]
    logger.info("Pipeline run %s started (dag=%s run=%s)", run_id, dag_id, dag_run_id)
    return run_id


def finish_pipeline_run(pipeline_run_id: uuid.UUID, conn=None) -> str:
    """Roll table-run results up into the pipeline run. Returns SUCCESS | PARTIAL | FAILED."""
    row = _q(
        conn,
        """
        WITH latest AS (   -- only the LAST attempt per table counts
            SELECT DISTINCT ON (COALESCE(config_id, 0), processing_layer, target_table) status
            FROM audit.table_runs
            WHERE pipeline_run_id = %(id)s
            ORDER BY COALESCE(config_id, 0), processing_layer, target_table,
                     attempt_number DESC NULLS LAST, started_at DESC
        ), agg AS (
            SELECT count(*)                                   AS total,
                   count(*) FILTER (WHERE status = 'SUCCESS') AS ok,
                   count(*) FILTER (WHERE status = 'FAILED')  AS failed,
                   count(*) FILTER (WHERE status = 'SKIPPED') AS skipped,
                   count(*) FILTER (WHERE status = 'RUNNING') AS running
            FROM latest
        )
        UPDATE audit.pipeline_runs p
        SET total_tables      = agg.total,
            successful_tables = agg.ok,
            failed_tables     = agg.failed + agg.running,
            skipped_tables    = agg.skipped,
            status = CASE WHEN agg.failed + agg.running = 0 THEN 'SUCCESS'
                          WHEN agg.ok = 0                   THEN 'FAILED'
                          ELSE 'PARTIAL' END,
            ended_at = clock_timestamp(),
            duration_seconds = EXTRACT(EPOCH FROM clock_timestamp() - p.started_at)
        FROM agg
        WHERE p.pipeline_run_id = %(id)s
        RETURNING p.status
        """,
        {"id": pipeline_run_id},
        fetch="one",
    )
    status = row["status"]
    logger.info("Pipeline run %s finished: %s", pipeline_run_id, status)
    return status


def finalize_dag_run(dag_id: str, dag_run_id: str, conn=None) -> str | None:
    """Close this DAG run's pipeline run after every task has finished.

    Reaps table_runs that stayed RUNNING (killed worker) so the rollup settles,
    then recomputes. Returns the final status, or None if the run was never
    recorded. Safe to run twice.
    """
    row = _q(
        conn,
        """
        SELECT pipeline_run_id FROM audit.pipeline_runs
        WHERE dag_id = %s AND dag_run_id = %s
        """,
        (dag_id, dag_run_id),
        fetch="one",
    )
    if row is None:
        return None
    run_id = row["pipeline_run_id"]
    reaped = _q(
        conn,
        """
        UPDATE audit.table_runs
        SET status = 'FAILED', ended_at = clock_timestamp(),
            duration_seconds = EXTRACT(EPOCH FROM clock_timestamp() - started_at),
            execution_metadata = COALESCE(execution_metadata, '{}'::jsonb)
                || '{"task_never_finished": true}'::jsonb
        WHERE pipeline_run_id = %s AND status = 'RUNNING'
        """,
        (run_id,),
    )
    if reaped:
        logger.warning(
            "Finalize reaped %d RUNNING table run(s) for pipeline run %s",
            reaped,
            run_id,
        )
    return finish_pipeline_run(run_id, conn=conn)


# ----------------------------------------------------------- source registry
def get_enabled_tables(source_name: str, conn=None) -> list[dict]:
    """All enabled table configs of an enabled source (joined with source info)."""
    return _q(
        conn,
        """
        SELECT t.*, r.source_name, r.source_type
        FROM audit.source_tables t
        JOIN audit.source_registry r USING (source_id)
        WHERE r.source_name = %s AND r.is_enabled AND t.is_enabled
        ORDER BY t.config_id
        """,
        (source_name,),
        fetch="all",
    )


# ---------------------------------------------------------------- table runs
def start_table_run(
    pipeline_run_id: uuid.UUID,
    cfg: dict,
    *,
    processing_layer: str = "raw",
    operation_type: str | None = None,
    airflow_task_id: str | None = None,
    airflow_try_number: int | None = None,
    conn=None,
) -> uuid.UUID:
    table_run_id = uuid.uuid4()
    _q(
        conn,
        """
        INSERT INTO audit.table_runs
            (table_run_id, pipeline_run_id, config_id, source_id, source_table, target_table,
             processing_layer, operation_type, attempt_number, airflow_task_id,
             airflow_try_number, execution_metadata)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s,
                (SELECT COALESCE(MAX(attempt_number), 0) + 1
                   FROM audit.table_runs
                   WHERE pipeline_run_id = %s AND config_id IS NOT DISTINCT FROM %s),
                %s, %s, '{}'::jsonb)
        """,
        (
            table_run_id,
            pipeline_run_id,
            cfg["config_id"],
            cfg["source_id"],
            f"{cfg['source_schema']}.{cfg['source_table']}",
            f"{cfg['target_schema']}.{cfg['target_table']}",
            processing_layer,
            operation_type or cfg["load_strategy"],
            pipeline_run_id,
            cfg["config_id"],
            airflow_task_id,
            airflow_try_number,
        ),
    )
    return table_run_id


def finish_table_run(
    table_run_id: uuid.UUID,
    status: str,
    *,
    rows_extracted: int | None = None,
    rows_landed: int | None = None,
    watermark_start: str | None = None,
    watermark_end: str | None = None,
    error_id: int | None = None,
    metadata: dict | None = None,
    conn=None,
) -> None:
    if status not in {"SUCCESS", "FAILED", "SKIPPED"}:
        raise ValueError(f"Invalid final status: {status}")
    _q(
        conn,
        """
        UPDATE audit.table_runs
        SET status = %s,
            ended_at = clock_timestamp(),
            duration_seconds = EXTRACT(EPOCH FROM clock_timestamp() - started_at),
            rows_extracted = COALESCE(%s, rows_extracted),
            rows_landed    = COALESCE(%s, rows_landed),
            watermark_start = COALESCE(%s, watermark_start),
            watermark_end   = COALESCE(%s, watermark_end),
            error_id        = COALESCE(%s, error_id),
            execution_metadata = COALESCE(execution_metadata, '{}'::jsonb) || %s::jsonb
        WHERE table_run_id = %s
        """,
        (
            status,
            rows_extracted,
            rows_landed,
            watermark_start,
            watermark_end,
            error_id,
            Json(metadata or {}),
            table_run_id,
        ),
    )


def log_error(
    exc: BaseException,
    *,
    pipeline_run_id: uuid.UUID | None = None,
    table_run_id: uuid.UUID | None = None,
    cfg: dict | None = None,
    processing_layer: str = "raw",
    severity: str = "ERROR",
    conn=None,
) -> int:
    """Record an exception in audit.pipeline_errors and link it to the table run."""
    category, recoverable = _classify(exc)
    attempt = None
    if table_run_id is not None:
        r = _q(
            conn,
            "SELECT attempt_number FROM audit.table_runs WHERE table_run_id = %s",
            (table_run_id,),
            fetch="one",
        )
        attempt = r["attempt_number"] if r else None

    row = _q(
        conn,
        """
        INSERT INTO audit.pipeline_errors
            (pipeline_run_id, table_run_id, source_table, target_table, processing_layer,
             error_category, severity, error_message, error_details, retry_attempt,
             is_recoverable, resolution_status)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'OPEN')
        RETURNING error_id
        """,
        (
            pipeline_run_id,
            table_run_id,
            f"{cfg['source_schema']}.{cfg['source_table']}" if cfg else None,
            f"{cfg['target_schema']}.{cfg['target_table']}" if cfg else None,
            processing_layer,
            category,
            severity,
            _redact(str(exc))[:10000],
            Json(
                {
                    "exception_type": type(exc).__name__,
                    "traceback": _redact("".join(traceback.format_exception(exc)))[
                        -20000:
                    ],
                }
            ),
            attempt,
            recoverable,
        ),
        fetch="one",
    )
    error_id = row["error_id"]
    if table_run_id is not None:
        _q(
            conn,
            "UPDATE audit.table_runs SET error_id = %s WHERE table_run_id = %s",
            (error_id, table_run_id),
        )
    return error_id


@dataclass
class TableRun:
    """Handle yielded by table_run(); set the fields, the context manager persists them."""

    table_run_id: uuid.UUID
    pipeline_run_id: uuid.UUID
    cfg: dict
    rows_extracted: int | None = None
    rows_landed: int | None = None
    watermark_start: str | None = None
    watermark_end: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)
    status: str = "SUCCESS"

    def skip(self, reason: str) -> None:
        """Mark this run SKIPPED (e.g. no new data)."""
        self.status = "SKIPPED"
        self.metadata["skip_reason"] = reason


@contextmanager
def table_run(
    pipeline_run_id: uuid.UUID,
    cfg: dict,
    *,
    processing_layer: str = "raw",
    operation_type: str | None = None,
    airflow_task_id: str | None = None,
    airflow_try_number: int | None = None,
) -> Iterator[TableRun]:
    """Start a table run; on exit mark SUCCESS/SKIPPED, or log the error + FAILED and re-raise."""
    run = TableRun(
        table_run_id=start_table_run(
            pipeline_run_id,
            cfg,
            processing_layer=processing_layer,
            operation_type=operation_type,
            airflow_task_id=airflow_task_id,
            airflow_try_number=airflow_try_number,
        ),
        pipeline_run_id=pipeline_run_id,
        cfg=cfg,
    )
    label = f"{cfg['source_schema']}.{cfg['source_table']}"
    logger.info("[%s] table run %s started", label, run.table_run_id)
    try:
        yield run
    except BaseException as exc:
        try:  # never let audit problems hide the real error
            error_id = log_error(
                exc,
                pipeline_run_id=pipeline_run_id,
                table_run_id=run.table_run_id,
                cfg=cfg,
                processing_layer=processing_layer,
            )
            finish_table_run(
                run.table_run_id,
                "FAILED",
                rows_extracted=run.rows_extracted,
                watermark_start=run.watermark_start,
                watermark_end=run.watermark_end,
                error_id=error_id,
                metadata=run.metadata,
            )
        except Exception:
            logger.exception("[%s] could not write failure to audit tables", label)
        logger.error("[%s] FAILED: %s", label, _redact(str(exc))[:500])
        raise
    else:
        finish_table_run(
            run.table_run_id,
            run.status,
            rows_extracted=run.rows_extracted,
            rows_landed=run.rows_landed,
            watermark_start=run.watermark_start,
            watermark_end=run.watermark_end,
            metadata=run.metadata,
        )
        logger.info(
            "[%s] %s | extracted=%s landed=%s",
            label,
            run.status,
            run.rows_extracted,
            run.rows_landed,
        )
        if run.status == "SKIPPED" and run.metadata.get("skip_reason"):
            logger.info("[%s] skipped: %s", label, run.metadata["skip_reason"])


# ---------------------------------------------------------------- watermarks
# Source->raw progress lives in audit.extract_watermarks; audit.etl_watermarks
# is the staging layer's raw->staging progress on the same config_id, so the
# two layers must never share a value.
def get_watermark(config_id: int, conn=None) -> dict | None:
    return _q(
        conn,
        "SELECT * FROM audit.extract_watermarks WHERE config_id = %s",
        (config_id,),
        fetch="one",
    )


def begin_batch(
    cfg: dict, batch_start: str | None, batch_end: str | None, conn=None
) -> dict:
    """Record the batch window about to be loaded; returns {lock_version, last_watermark_value}.

    Does NOT move the watermark and does not bump lock_version.
    """
    return _q(
        conn,
        """
        INSERT INTO audit.extract_watermarks
            (source_id, config_id, watermark_column, watermark_strategy,
             current_batch_start, current_batch_end)
        VALUES (%s, %s, %s, %s, %s, %s)
        ON CONFLICT (config_id) DO UPDATE
        SET watermark_column    = EXCLUDED.watermark_column,
            watermark_strategy  = EXCLUDED.watermark_strategy,
            current_batch_start = EXCLUDED.current_batch_start,
            current_batch_end   = EXCLUDED.current_batch_end,
            updated_at          = clock_timestamp()
        RETURNING lock_version, last_watermark_value
        """,
        (
            cfg["source_id"],
            cfg["config_id"],
            cfg.get("incremental_column"),
            cfg.get("watermark_strategy"),
            batch_start,
            batch_end,
        ),
        fetch="one",
    )


def advance_watermark(
    config_id: int,
    new_value: str,
    *,
    expected_lock_version: int,
    table_run_id: uuid.UUID,
    pipeline_run_id: uuid.UUID,
    conn,
) -> None:
    """Move the watermark forward — call INSIDE the same transaction as the data promotion.

    `conn` is mandatory on purpose: data + watermark commit together or not at all.
    Raises WatermarkConflict (=> the caller's transaction rolls back) if another run won.
    """
    changed = _q(
        conn,
        """
        UPDATE audit.extract_watermarks
        SET previous_watermark_value  = last_watermark_value,
            last_watermark_value      = %s,
            last_success_pipeline_run = %s,
            last_success_table_run    = %s,
            last_success_at           = clock_timestamp(),
            lock_version              = lock_version + 1,
            updated_at                = clock_timestamp()
        WHERE config_id = %s AND lock_version = %s
        """,
        (new_value, pipeline_run_id, table_run_id, config_id, expected_lock_version),
    )
    if changed == 0:
        raise WatermarkConflict(
            f"config_id={config_id}: watermark was changed by another run (expected lock_version={expected_lock_version})"
        )


def seed_watermark(cfg: dict, value: str, *, force: bool = False, conn=None) -> bool:
    """Bootstrap last_watermark_value for a newly-incremental config.

    Only fills an empty watermark unless force=True, so re-running can never
    rewind a watermark that later runs already advanced. Returns True if seeded.
    """
    seeded = _q(
        conn,
        """
        INSERT INTO audit.extract_watermarks
            (source_id, config_id, watermark_column, watermark_strategy,
             last_watermark_value)
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (config_id) DO UPDATE
        SET watermark_column    = EXCLUDED.watermark_column,
            watermark_strategy  = EXCLUDED.watermark_strategy,
            last_watermark_value = EXCLUDED.last_watermark_value,
            updated_at          = clock_timestamp()
        WHERE audit.extract_watermarks.last_watermark_value IS NULL OR %s
        RETURNING config_id
        """,
        (
            cfg["source_id"],
            cfg["config_id"],
            cfg["incremental_column"],
            cfg["watermark_strategy"],
            value,
            force,
        ),
        fetch="one",
    )
    return seeded is not None


# -------------------------------------------------------------- data quality
def log_dq_result(
    *,
    check_name: str,
    status: str,
    records_checked: int = 0,
    records_failed: int = 0,
    details: dict | None = None,
    pipeline_run_id: uuid.UUID | None = None,
    table_run_id: uuid.UUID | None = None,
    config_id: int | None = None,
    conn=None,
) -> None:
    status = status.upper()
    if status not in {"PASSED", "FAILED", "WARNING"}:
        raise ValueError("status must be PASSED, FAILED or WARNING")
    _q(
        conn,
        """
        INSERT INTO audit.data_quality_results
            (pipeline_run_id, table_run_id, config_id, check_name, status,
             records_checked, records_failed, details)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
        """,
        (
            pipeline_run_id,
            table_run_id,
            config_id,
            check_name,
            status,
            records_checked,
            records_failed,
            Json(details or {}),
        ),
    )


# ----------------------------------------------------------------- hygiene
def fail_stale_runs(max_age_hours: int = 6, conn=None) -> int:
    """Mark RUNNING runs older than N hours FAILED (killed worker, OOM, power loss).

    Call at the start of each DAG run. Returns number of table runs reaped.
    """
    reaped = _q(
        conn,
        """
        UPDATE audit.table_runs
        SET status = 'FAILED', ended_at = clock_timestamp(),
            duration_seconds = EXTRACT(EPOCH FROM clock_timestamp() - started_at),
            execution_metadata = COALESCE(execution_metadata, '{}'::jsonb) || '{"stale_reaped": true}'::jsonb
        WHERE status = 'RUNNING' AND started_at < clock_timestamp() - make_interval(hours => %s)
        """,
        (max_age_hours,),
    )
    _q(
        conn,
        """
        UPDATE audit.pipeline_runs
        SET status = 'FAILED', ended_at = clock_timestamp(),
            duration_seconds = EXTRACT(EPOCH FROM clock_timestamp() - started_at)
        WHERE status = 'RUNNING' AND started_at < clock_timestamp() - make_interval(hours => %s)
        """,
        (max_age_hours,),
    )
    if reaped:
        logger.warning("Marked %d stale RUNNING table run(s) as FAILED", reaped)
    return reaped
