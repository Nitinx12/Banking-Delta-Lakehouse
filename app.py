"""Streamlit host for the landing page and a read-only audit panel."""

import sys
from pathlib import Path

import pandas as pd
import streamlit as st
from sqlalchemy import create_engine
from sqlalchemy.engine import URL, Engine
from sqlalchemy.exc import SQLAlchemyError

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "site"))  # helpers sit next to index.html

import site_audit  # noqa: E402
import site_render  # noqa: E402

st.set_page_config(page_title="Banking Delta Lakehouse", page_icon="🏦", layout="wide")
st.markdown(
    "<style>#MainMenu,header,footer{visibility:hidden}"
    ".block-container{padding:.5rem 1rem 0!important;max-width:100%!important}</style>",
    unsafe_allow_html=True,
)


def db_configured() -> bool:
    try:
        return "postgres" in st.secrets
    except FileNotFoundError:  # no secrets file at all
        return False


@st.cache_resource
def get_engine() -> Engine:
    cfg = st.secrets["postgres"]
    url = URL.create(
        "postgresql+psycopg2",
        username=cfg["user"],
        password=cfg["password"],
        host=cfg["host"],
        port=int(cfg.get("port", 5432)),
        database=cfg["dbname"],
    )
    return create_engine(
        url,
        pool_pre_ping=True,
        connect_args={"connect_timeout": 10, "sslmode": cfg.get("sslmode", "prefer")},
    )


@st.cache_data(ttl=60)
def run_query(sql: str, limit: int = 50) -> pd.DataFrame:
    """Run one allowlisted audit query and return its newest rows."""
    return site_audit.read_query(get_engine(), sql, limit)


@st.cache_data(ttl=60)
def live_snapshot(configured: bool) -> dict | None:
    """What index.html replays; None keeps the page in its offline demo mode."""
    if not configured:
        return None
    return site_audit.live_payload(run_query, True)


def load_site(live: dict | None) -> str:
    return site_render.render(ROOT, live)


site_tab, live_tab = st.tabs(["Pipeline site", "Live audit status"])

with site_tab:
    st.iframe(load_site(live_snapshot(db_configured())), height=1000)

with live_tab:
    if not db_configured():
        st.info(
            "Live status is off. Add a `[postgres]` block (host, port, dbname, user, password) "
            "under **Settings → Secrets** in Streamlit Cloud, or in `.streamlit/secrets.toml` locally. "
            "Use a read-only user with SELECT on the `audit` schema."
        )
    else:
        left, right = st.columns([4, 1])
        left.caption("Read-only view of the audit schema. Refreshes every 60 seconds.")
        if right.button("Refresh now"):
            st.cache_data.clear()
        tabs = st.tabs(list(site_audit.QUERIES))
        for tab, (label, sql) in zip(tabs, site_audit.QUERIES.items(), strict=True):
            with tab:
                try:
                    df = run_query(sql)
                    st.dataframe(df, width="stretch", hide_index=True)
                    st.caption(f"{label} · latest {len(df)} rows")
                except (SQLAlchemyError, ValueError, TypeError, KeyError) as exc:
                    st.error(f"Could not read {label}. {site_audit.audit_error(exc)}")
