"""Read-only queries against the audit schema for the landing page's live panel."""

from __future__ import annotations

import json
import re
from typing import Any, Callable

import pandas as pd
from sqlalchemy import text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError

# Fixed allowlist: the only SQL this app will ever run.
QUERIES: dict[str, str] = {
    "Pipeline runs": "select * from audit.fn_pipeline_summary(7, null::text)",
    "Table runs": "select * from audit.fn_table_runs(null::uuid, 7, null::text)",
    "Data quality": "select * from audit.fn_dq_summary(7, null::text)",
    "DQ latest": "select * from audit.v_dq_latest",
}

# The audit tables are bounded, but cap anyway so one view can never flood the page.
MAX_ROWS = 500
_SECRET_RE = re.compile(
    r"(?i)\b(password|passwd|token|secret|api[_-]?key)\b\s*[:=]\s*\S+"
)


def read_query(engine: Engine, sql: str, limit: int = 50) -> pd.DataFrame:
    """Run one allowlisted SELECT and return the newest-looking rows, capped at `limit`."""
    paged = f"select * from ({sql}) _page limit :cap"
    with engine.connect() as conn:
        df = pd.read_sql(text(paged), conn, params={"cap": MAX_ROWS})
    return _newest_first(df).head(limit if limit > 0 else MAX_ROWS)


def _newest_first(df: pd.DataFrame) -> pd.DataFrame:
    """Sort by the last timestamp-like column so the panel shows recent rows first."""
    order = next(
        (c for c in reversed(df.columns) if c.endswith(("_at", "_date"))), None
    )
    if order is None:
        return df
    return df.sort_values(order, ascending=False, na_position="last", kind="stable")


def records(df: pd.DataFrame) -> list[dict[str, Any]]:
    """JSON-safe rows: timestamps ISO, missing values null, UUIDs as strings."""
    return json.loads(
        df.to_json(orient="records", date_format="iso", default_handler=str)
    )


def live_payload(
    read: Callable[..., pd.DataFrame], configured: bool
) -> dict[str, list[dict[str, Any]]]:
    """Build the payload index.html replays; empty when the database is unavailable."""
    if not configured:
        return {}
    try:
        return {
            "batches": records(read(QUERIES["Pipeline runs"], 5)),
            "tables": records(read(QUERIES["Table runs"], 200)),
            "dq": records(read(QUERIES["Data quality"], 200)),
        }
    except (SQLAlchemyError, ValueError, TypeError, KeyError):
        return {}


def audit_error(exc: BaseException) -> str:
    """One short line describing a failed audit read, with credential shapes redacted."""
    msg = _SECRET_RE.sub(lambda m: f"{m.group(1)}=***", f"{type(exc).__name__}: {exc}")
    return msg[:300]
