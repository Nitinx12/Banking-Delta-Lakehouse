# Read only audit queries to the context dictionary; one try per section.
from __future__ import annotations

import os
import re
from datetime import UTC, datetime
from typing import Any

from src.utils.audit import _redact
from src.utils.logger import get_logger

from . import paths

logger = get_logger(__name__)

MAX_MESSAGE_CHARS = 300

STEPS = [
    ("preflight", "orchestration"),
    ("extract_mongo", "source"),
    ("extract_databricks", "source"),
    ("extract_mysql", "source"),
    ("raw_tests", "raw"),
    ("staging_load", "staging"),
    ("staging_tests", "staging"),
    ("analytics_load", "analytics"),
    ("analytics_tests", "analytics"),
    ("marts_load", "marts"),
    ("marts_tests", "marts"),
    ("publish", "publish"),
    ("finalize_audit", "audit"),
]


def _connect():
    import psycopg2

    conn = psycopg2.connect(
        host=os.environ.get("PG_HOST"),
        port=int(os.environ.get("PG_PORT", "5432")),
        dbname=os.environ.get("PG_DB"),
        user=os.environ.get("PG_USER"),
        password=os.environ.get("PG_PASS", ""),
        connect_timeout=10,
        application_name="banking-report-collect",
        options="-c default_transaction_read_only=on",
    )
    conn.set_session(readonly=True, autocommit=True)
    return conn


def _fetch(conn, query: str, params: tuple = ()) -> list[dict[str, Any]]:
    from psycopg2.extras import RealDictCursor

    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(query, params)
        return [dict(row) for row in cur.fetchall()]


_EMPTY = {
    "run": {},
    "steps": [],
    "tables": [],
    "dq": [],
    "errors": [],
    "freshness": [],
    "trends": [],
}


def _section(context: dict[str, Any], name: str, collector) -> None:
    try:
        context[name] = collector()
    except Exception as exc:  # noqa: BLE001 - one failure degrades one section
        context.setdefault("sections_failed", []).append(name)
        context[name] = _EMPTY.get(name, [])
        logger.warning("report section %s degraded: %s", name, type(exc).__name__)


def _iso(value: Any) -> Any:
    return value.isoformat() if hasattr(value, "isoformat") else value


def _as_datetime(value: Any) -> datetime | None:
    """Parse an ISO string or pass a datetime through; None when unusable."""
    if isinstance(value, datetime):
        return value
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value)
        except ValueError:
            return None
    return None


def _seconds(value: Any) -> float | None:
    if value is None:
        return None
    return float(value)


def _window_seconds(window: str) -> float:
    match = re.fullmatch(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", window)
    if not match:
        return 0.0
    days, hours, minutes, seconds = (int(g or 0) for g in match.groups())
    return float(days * 86400 + hours * 3600 + minutes * 60 + seconds)


def collect(
    *,
    kind: str,
    dag_id: str | None,
    dag_run_id: str | None,
    conn=None,
) -> dict[str, Any]:
    """Build the context for one run; degraded sections land in sections_failed."""
    own = conn if conn is not None else _connect()
    context: dict[str, Any] = {
        "schema_version": 2,
        "meta": _meta(kind, dag_id, dag_run_id),
        "run": {},
        "steps": [],
        "tables": [],
        "dq": [],
        "errors": [],
        "freshness": [],
        "trends": [],
        "events": [],
        "verdict": {"severity": "UNKNOWN", "label": "UNKNOWN"},
        "sections_failed": [],
    }

    def _run():
        row = _fetch(
            own,
            """
            SELECT status, total_tables, successful_tables, failed_tables,
                   skipped_tables, started_at, ended_at, duration_seconds
            FROM audit.pipeline_runs
            WHERE dag_id = %s
              AND (%s::text IS NULL OR dag_run_id = %s)
            ORDER BY started_at DESC
            LIMIT 1
            """,
            (dag_id, dag_run_id, dag_run_id),
        )
        if not row:
            raise LookupError("no pipeline_runs row for this dag run")
        latest = row[0]
        return {
            "status": latest["status"],
            "duration_s": _seconds(latest["duration_seconds"]),
            "total_tables": latest["total_tables"],
            "successful_tables": latest["successful_tables"],
            "failed_tables": latest["failed_tables"],
            "skipped_tables": latest["skipped_tables"],
            "started_at": _iso(latest["started_at"]),
            "ended_at": _iso(latest["ended_at"]),
        }

    def _pipeline_run_id() -> Any:
        row = _fetch(
            own,
            """
            SELECT pipeline_run_id
            FROM audit.pipeline_runs
            WHERE dag_id = %s
              AND (%s::text IS NULL OR dag_run_id = %s)
            ORDER BY started_at DESC
            LIMIT 1
            """,
            (dag_id, dag_run_id, dag_run_id),
        )
        return row[0]["pipeline_run_id"] if row else None

    def _median_rows() -> dict[tuple[str, str], int]:
        """Trailing median of rows landed per table over the recent runs."""
        try:
            rows = _fetch(
                own,
                """
                SELECT processing_layer, target_table,
                       percentile_cont(0.5) WITHIN GROUP (ORDER BY rows_landed)
                           AS median_rows
                FROM audit.table_runs
                WHERE pipeline_run_id IN (
                    SELECT pipeline_run_id FROM audit.pipeline_runs
                    WHERE dag_id = %s
                    ORDER BY started_at DESC
                    LIMIT %s
                )
                GROUP BY processing_layer, target_table
                """,
                (dag_id, int(os.environ.get("REPORT_TREND_RUNS", "14"))),
            )
        except Exception as exc:  # noqa: BLE001 - a missing median never blocks the list
            logger.warning("row medians degraded: %s", type(exc).__name__)
            return {}
        return {
            (str(row["processing_layer"]), str(row["target_table"])): int(
                row["median_rows"]
            )
            for row in rows
            if row.get("median_rows") is not None
        }

    def _tables():
        run_id = _pipeline_run_id()
        rows = _fetch(
            own,
            """
            SELECT DISTINCT ON (processing_layer, target_table)
                processing_layer, target_table, attempt_number, status,
                rows_extracted, rows_landed, watermark_start, watermark_end
            FROM audit.table_runs
            WHERE pipeline_run_id = %s
            ORDER BY processing_layer, target_table, attempt_number DESC
            """,
            (run_id,),
        )
        medians = _median_rows()
        return [
            {
                "layer": row["processing_layer"],
                "table": row["target_table"],
                "label": f"{row['processing_layer']}.{row['target_table']}",
                "median_rows": medians.get(
                    (str(row["processing_layer"]), str(row["target_table"]))
                ),
                "status": row["status"],
                "rows_extracted": row["rows_extracted"],
                "rows_landed": row["rows_landed"],
                "watermark_start": row["watermark_start"],
                "watermark_end": row["watermark_end"],
                "attempts": row["attempt_number"],
            }
            for row in rows
        ]

    def _steps():
        run_id = _pipeline_run_id()
        task_rows = _fetch(
            own,
            """
            SELECT airflow_task_id, max(attempt_number) AS attempts,
                   min(started_at) AS started_at, max(ended_at) AS ended_at,
                   bool_or(status = 'SUCCESS') AS any_success,
                   bool_or(status = 'FAILED') AS any_failed
            FROM audit.table_runs
            WHERE pipeline_run_id = %s AND airflow_task_id IS NOT NULL
            GROUP BY airflow_task_id
            """,
            (run_id,),
        )
        evidence = {str(row["airflow_task_id"]): row for row in task_rows}
        run_started = (context.get("run") or {}).get("started_at")
        steps = []
        for index, (name, layer) in enumerate(STEPS, start=1):
            row = evidence.get(name)
            if row is None:
                state, duration, attempts = "idle", None, None
            elif row["any_failed"]:
                state, duration = "bad", _duration(row)
                attempts = row["attempts"]
            elif row["any_success"]:
                state, duration = "ok", _duration(row)
                attempts = row["attempts"]
            else:
                state, duration, attempts = "warn", _duration(row), row["attempts"]
            steps.append(
                {
                    "id": f"n{index:02d}",
                    "name": name,
                    "layer": layer,
                    "state": state,
                    "duration_s": duration,
                    "attempts": attempts,
                    **_timing(row, run_started),
                }
            )
        return steps

    def _timing(row: dict[str, Any] | None, run_started: Any) -> dict[str, Any]:
        """Evidence flag and second offsets of one task from the run start."""
        if row is None:
            return {"evidence": False, "start_offset_s": None, "end_offset_s": None}
        start = _offset(row.get("started_at"), run_started)
        end = _offset(row.get("ended_at"), run_started)
        if start is None or end is None:
            return {"evidence": False, "start_offset_s": None, "end_offset_s": None}
        return {"evidence": True, "start_offset_s": start, "end_offset_s": end}

    def _offset(value: Any, reference: Any) -> float | None:
        """Seconds from the reference timestamp, never negative, None when unknown."""
        moment = _as_datetime(value)
        base = _as_datetime(reference)
        if moment is None or base is None:
            return None
        try:
            return float(max(0.0, (moment - base).total_seconds()))
        except TypeError:
            return None

    def _duration(row: dict[str, Any]) -> float | None:
        if row.get("started_at") is None or row.get("ended_at") is None:
            return None
        return (row["ended_at"] - row["started_at"]).total_seconds()

    def _dq():
        rows = _fetch(
            own,
            """
            SELECT layer, script_name, status, violation_count, started_at
            FROM audit.v_dq_latest
            ORDER BY layer, script_name
            """,
        )
        return [
            {
                "layer": row["layer"],
                "script_name": row["script_name"],
                "status": row["status"],
                "violation_count": row["violation_count"],
                "checked_at": _iso(row["started_at"]),
            }
            for row in rows
        ]

    def _errors():
        run_id = _pipeline_run_id()
        rows = _fetch(
            own,
            """
            SELECT error_category, severity, error_message, target_table,
                   processing_layer, error_timestamp
            FROM audit.pipeline_errors
            WHERE pipeline_run_id = %s
            ORDER BY error_timestamp
            """,
            (run_id,),
        )
        return [
            {
                "category": row["error_category"] or "UNKNOWN",
                "severity": row["severity"] or "MAJOR",
                "message": _redact(str(row["error_message"] or ""))[:MAX_MESSAGE_CHARS],
                "timestamp": _iso(row["error_timestamp"]),
                "table": row["target_table"],
                "layer": row["processing_layer"],
            }
            for row in rows
        ]

    def _freshness():
        from psycopg2 import sql

        config = paths.load_report_config()
        windows = paths.load_slo_config()
        default_window = str(config["thresholds"]["freshness_default_window"])
        registry = _fetch(
            own,
            """
            SELECT target_table, load_strategy, incremental_column, source_id
            FROM audit.source_tables
            WHERE target_schema = 'raw' AND is_enabled
            ORDER BY target_table
            """,
        )
        rows = []
        now = datetime.now(UTC)
        for entry in registry:
            table = str(entry["target_table"])
            load_strategy = entry["load_strategy"]

            # For full-load tables, freshness is not applicable (refreshed every run)
            # For incremental tables, use extract watermark (source freshness)
            if load_strategy == "full":
                # Full-load tables are refreshed every run; measure source business timestamp if available
                # For now, mark as N/A since _loaded_at reflects run time, not source freshness
                query = sql.SQL("SELECT max(_loaded_at) AS loaded FROM raw.{}").format(
                    sql.Identifier(table)
                )
                loaded = _fetch(own, query.as_string(own))[0]["loaded"]
                age_s = None if loaded is None else (now - loaded).total_seconds()
                rows.append(
                    {
                        "table": table,
                        "age_s": age_s,
                        "window": "N/A (full reload)",
                        "breached": False,
                        "severity": "INFO",
                        "note": "Full reload; _loaded_at reflects run time",
                    }
                )
            else:
                # Incremental tables: use extract watermark for source freshness
                # Get the last successful extract watermark
                wm = _fetch(
                    own,
                    """
                    SELECT last_watermark_value
                    FROM audit.extract_watermarks
                    WHERE config_id = (
                        SELECT config_id FROM audit.source_tables
                        WHERE target_table = %s AND target_schema = 'raw'
                    )
                    """,
                    (table,),
                )
                watermark_value = wm[0]["last_watermark_value"] if wm else None

                if watermark_value is None:
                    # No watermark yet; fall back to _loaded_at
                    query = sql.SQL(
                        "SELECT max(_loaded_at) AS loaded FROM raw.{}"
                    ).format(sql.Identifier(table))
                    loaded = _fetch(own, query.as_string(own))[0]["loaded"]
                    age_s = None if loaded is None else (now - loaded).total_seconds()
                else:
                    # Parse watermark as UTC and compute age
                    try:
                        # Watermark is stored in canonical UTC format (+00:00)
                        from datetime import datetime as dt

                        wm_dt = dt.fromisoformat(watermark_value)
                        if wm_dt.tzinfo is None:
                            wm_dt = wm_dt.replace(tzinfo=UTC)
                        age_s = (now - wm_dt).total_seconds()
                    except (ValueError, AttributeError):
                        # Fallback
                        query = sql.SQL(
                            "SELECT max(_loaded_at) AS loaded FROM raw.{}"
                        ).format(sql.Identifier(table))
                        loaded = _fetch(own, query.as_string(own))[0]["loaded"]
                        age_s = (
                            None if loaded is None else (now - loaded).total_seconds()
                        )

                slo = windows.get("tables", {}).get(table, {})
                window = str(slo.get("window", default_window))
                breached = age_s is not None and age_s > _window_seconds(window)
                rows.append(
                    {
                        "table": table,
                        "age_s": age_s,
                        "window": window,
                        "breached": breached,
                        "severity": slo.get("severity", "WARNING"),
                    }
                )
        return rows

    def _trends():
        rows = _fetch(
            own,
            """
            SELECT dag_run_id, status, duration_seconds, ended_at
            FROM audit.pipeline_runs
            WHERE dag_id = %s AND status <> 'RUNNING'
            ORDER BY started_at DESC
            LIMIT %s
            """,
            (dag_id, int(os.environ.get("REPORT_TREND_RUNS", "14"))),
        )
        trends = []
        for row in reversed(rows):
            run_id = _fetch(
                own,
                """
                SELECT coalesce(sum(rows_landed) FILTER (WHERE processing_layer = 'raw'), 0)
                       AS rows_landed,
                       count(*) FILTER (WHERE status = 'FAILED') AS failed_tables
                FROM audit.table_runs
                WHERE pipeline_run_id = (
                    SELECT pipeline_run_id FROM audit.pipeline_runs
                    WHERE dag_id = %s AND dag_run_id = %s
                )
                """,
                (dag_id, row["dag_run_id"]),
            )[0]
            dq_fails = _fetch(
                own,
                """
                SELECT count(*) AS n FROM audit.dq_run
                WHERE status = 'FAIL'
                  AND started_at >= (
                      SELECT started_at FROM audit.pipeline_runs
                      WHERE dag_id = %s AND dag_run_id = %s
                  )
                """,
                (dag_id, row["dag_run_id"]),
            )[0]["n"]
            trends.append(
                {
                    "run_key": paths.run_key(row["dag_run_id"]),
                    "status": row["status"],
                    "duration_s": _seconds(row["duration_seconds"]),
                    "rows_landed": int(run_id["rows_landed"]),
                    "failed_tables": int(run_id["failed_tables"]),
                    "dq_failures": int(dq_fails),
                }
            )
        return trends

    _section(context, "run", _run)
    _section(context, "tables", _tables)
    _section(context, "steps", _steps)
    _section(context, "dq", _dq)
    _section(context, "errors", _errors)
    _section(context, "freshness", _freshness)
    _section(context, "trends", _trends)
    if conn is None:
        own.close()
    return context


def _meta(kind: str, dag_id: str | None, dag_run_id: str | None) -> dict[str, Any]:
    from importlib import metadata

    from src.utils.config import PROJECT_ROOT

    git_sha = os.environ.get("GIT_SHA", "").strip() or "unknown"
    if git_sha == "unknown":  # containers carry GIT_SHA; host runs carry .git
        head = PROJECT_ROOT / ".git" / "HEAD"
        if head.is_file():
            text = head.read_text(encoding="utf-8").strip()
            if text.startswith("ref:"):
                ref = PROJECT_ROOT / ".git" / text.split(" ", 1)[1]
                git_sha = (
                    ref.read_text(encoding="utf-8").strip()
                    if ref.is_file()
                    else "unknown"
                )
            else:
                git_sha = text
    try:
        airflow_version = metadata.version("apache-airflow")
    except metadata.PackageNotFoundError:
        airflow_version = "unknown"
    return {
        "kind": kind,
        "generated_at": datetime.now(UTC).astimezone().isoformat(timespec="seconds"),
        "env": os.environ.get("ENVIRONMENT", "unknown"),
        "git_sha": git_sha[:12],
        "airflow_version": airflow_version,
        "dag_id": dag_id or "",
        "dag_run_id": dag_run_id or "",
    }
