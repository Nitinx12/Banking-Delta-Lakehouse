"""Shared sidebar controls and dataframe filter helpers."""

from __future__ import annotations

from datetime import datetime

import pandas as pd
import streamlit as st
from lib import db

REFRESH_CHOICES = {"Off": 0, "1 min": 60, "5 min": 300, "15 min": 900}


def render_sidebar() -> int:
    """Draw the global sidebar; return the auto-refresh interval in seconds."""
    with st.sidebar:
        st.markdown("### Controls")
        choice = st.selectbox("Auto-refresh", list(REFRESH_CHOICES), index=0)
        interval = REFRESH_CHOICES[choice]
        st.session_state["refresh_seconds"] = interval
        if st.button("Refresh now", width="stretch"):
            db.clear_cache()
            st.session_state["refreshed_at"] = datetime.now()
            st.rerun()
        st.divider()
        st.caption(
            "Source: Databricks SQL warehouse · marts schema\n\n"
            f"Cached queries expire after {db.DEFAULT_TTL_SECONDS // 60} min."
        )
    return interval


def month_range(
    df: pd.DataFrame,
    column: str = "month_start",
    label: str = "Month range",
) -> tuple[pd.Timestamp, pd.Timestamp]:
    """Two-handle month slider over a date column, defaults to the full history."""
    months = sorted(df[column].dropna().unique())
    if not months:
        return pd.Timestamp.min, pd.Timestamp.max
    labels = [pd.Timestamp(m).strftime("%b %Y") for m in months]
    start, end = st.select_slider(
        label,
        options=labels,
        value=(labels[0], labels[-1]),
    )
    start_ts = pd.Timestamp(datetime.strptime(start, "%b %Y"))
    end_ts = pd.Timestamp(datetime.strptime(end, "%b %Y")) + pd.offsets.MonthEnd(1)
    return start_ts, end_ts


def apply_month_range(
    df: pd.DataFrame,
    bounds: tuple[pd.Timestamp, pd.Timestamp],
    column: str = "month_start",
) -> pd.DataFrame:
    """Keep rows whose date column falls inside the chosen bounds."""
    start, end = bounds
    mask = (df[column] >= start) & (df[column] <= end)
    return df.loc[mask].copy()


def multiselect_all(
    label: str,
    options: list[str],
    *,
    key: str | None = None,
) -> list[str] | None:
    """Multiselect that returns None (no filter) while nothing is chosen."""
    chosen = st.multiselect(label, options, key=key)
    return chosen or None


def apply_multiselect(
    df: pd.DataFrame,
    column: str,
    chosen: list[str] | None,
) -> pd.DataFrame:
    """Filter a dataframe by an optional multiselect selection."""
    if not chosen:
        return df
    return df.loc[df[column].isin(chosen)].copy()


def numeric_summary(df: pd.DataFrame, columns: list[str]) -> pd.DataFrame:
    """Compact per-column counts used by the data-quality strip."""
    rows = []
    for col in columns:
        if col not in df.columns:
            continue
        series = df[col]
        rows.append(
            {
                "column": col.replace("_", " ").title(),
                "non-null": int(series.notna().sum()),
                "distinct": int(series.nunique(dropna=True)),
            }
        )
    return pd.DataFrame(rows)
