"""Databricks SQL warehouse connection and cached query execution."""

from __future__ import annotations

import os
import threading
from datetime import UTC, datetime

import pandas as pd
import streamlit as st
from streamlit.errors import StreamlitSecretNotFoundError

DEFAULT_TTL_SECONDS = 300

_LOCK = threading.Lock()
_LAST_SUCCESS: dict[str, datetime] = {}


def setting(name: str, default: str = "") -> str:
    """Read a config value from Streamlit secrets, falling back to the environment."""
    try:
        if name in st.secrets:
            return str(st.secrets[name])
    except StreamlitSecretNotFoundError:
        pass  # no secrets.toml present, so fall through to environment variables
    return os.environ.get(name, default)


def require_setting(name: str) -> str:
    """Read a required config value or raise with a fixable message."""
    value = setting(name)
    if not value:
        raise KeyError(
            f"Missing {name}: add it to .streamlit/secrets.toml or the environment"
        )
    return value


@st.cache_resource(show_spinner=False)
def get_connection():
    """Open one Databricks SQL connection, reused across Streamlit reruns."""
    from databricks import sql

    return sql.connect(
        server_hostname=require_setting("DATABRICKS_HOST"),
        http_path=require_setting("DATABRICKS_HTTP_PATH"),
        access_token=require_setting("DATABRICKS_TOKEN"),
        catalog=setting("DATABRICKS_CATALOG", "main"),
        schema=setting("DATABRICKS_MARTS_SCHEMA", "marts"),
    )


def ping() -> bool:
    """Check that the warehouse answers a trivial query."""
    try:
        conn = get_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT 1 AS ok")
            cur.fetchall()
    except Exception:  # noqa: BLE001 - health check must never crash the page
        return False
    return True


def last_success_at() -> datetime | None:
    """Timestamp of the most recent successful query on this kernel."""
    with _LOCK:
        return _LAST_SUCCESS.get("main")


@st.cache_data(ttl=DEFAULT_TTL_SECONDS, show_spinner="Querying Databricks…")
def run_query(query: str) -> pd.DataFrame:
    """Run one SELECT against Databricks and return a DataFrame (cached per TTL)."""
    from databricks.sql import DatabaseError, OperationalError

    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(query)
            try:
                df = cur.fetchall_arrow().to_pandas()
            except NotImplementedError:  # some result types only support row fetch
                df = pd.DataFrame(
                    cur.fetchall(), columns=[d[0] for d in cur.description]
                )
    except (DatabaseError, OperationalError) as exc:
        st.error(f"Databricks query failed: {exc}")
        st.stop()
    with _LOCK:
        _LAST_SUCCESS["main"] = datetime.now(UTC)
    return df


def clear_cache() -> None:
    """Drop every cached query so the next render hits the warehouse live."""
    run_query.clear()
