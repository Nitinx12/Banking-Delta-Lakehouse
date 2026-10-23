"""Canonical KPI numbers: computed once, printed by the cards, appendix and rules."""

from __future__ import annotations

import statistics
from typing import Any

from .collect import _window_seconds


def table_counts(context: dict[str, Any]) -> dict[str, int | None]:
    """Ok, failed, skipped and total tables; the run row is the fallback."""
    tables = context.get("tables") or []
    if not tables:
        run = context.get("run") or {}
        return {
            "total": run.get("total_tables"),
            "ok": run.get("successful_tables"),
            "failed": run.get("failed_tables"),
            "skipped": run.get("skipped_tables"),
        }
    ok = sum(1 for table in tables if table.get("status") == "SUCCESS")
    failed = sum(1 for table in tables if table.get("status") == "FAILED")
    return {
        "total": len(tables),
        "ok": ok,
        "failed": failed,
        "skipped": len(tables) - ok - failed,
    }


def raw_rows(context: dict[str, Any]) -> int | None:
    """Rows landed at the raw layer; None when no raw row was recorded."""
    values = [
        table.get("rows_landed")
        for table in context.get("tables") or []
        if table.get("layer") == "raw" and table.get("rows_landed") is not None
    ]
    return sum(int(value) for value in values) if values else None


def published_rows(context: dict[str, Any]) -> int | None:
    """Rows landed at the publish layer; None when nothing published."""
    values = [
        table.get("rows_landed")
        for table in context.get("tables") or []
        if table.get("layer") == "publish" and table.get("rows_landed") is not None
    ]
    return sum(int(value) for value in values) if values else None


def trailing_median(rows: list[dict[str, Any]], key: str) -> float | None:
    """Median over history, excluding the last row, which is the current run."""
    values = [float(row[key]) for row in rows[:-1] if row.get(key) is not None]
    if not values:
        return None
    return float(statistics.median(values))


def compute(context: dict[str, Any]) -> dict[str, Any]:
    """Every number docs/REPORT_REDESIGN.md section 4.1 defines, from one context."""
    dq = context.get("dq") or []
    run = context.get("run") or {}
    tables = context.get("tables") or []
    duration = run.get("duration_s")
    median_s = trailing_median(context.get("trends") or [], "duration_s")
    delta_pct: int | None = None
    if duration is not None and median_s:
        delta_pct = int(round((float(duration) / median_s - 1) * 100))
    fresh = [
        row for row in context.get("freshness") or [] if row.get("age_s") is not None
    ]
    shares = []
    for row in fresh:
        window = _window_seconds(str(row.get("window") or ""))
        if window > 0:
            shares.append(float(row["age_s"]) / window)
    return {
        "tables": table_counts(context),
        "rows": {"raw": raw_rows(context), "published": published_rows(context)},
        "dq": {
            "passed": sum(1 for row in dq if row.get("status") == "PASS"),
            "warnings": sum(1 for row in dq if row.get("status") == "WARNING"),
            "failed": sum(1 for row in dq if row.get("status") == "FAIL"),
            "total": len(dq),
        },
        "duration": {
            "duration_s": duration,
            "median_s": median_s,
            "delta_pct": delta_pct,
        },
        "freshest": {
            "worst_age_share": round(max(shares), 3) if shares else None,
            "breaches": sum(1 for row in fresh if row.get("breached")),
        },
        "retries": sum(1 for table in tables if (table.get("attempts") or 1) > 1),
    }
