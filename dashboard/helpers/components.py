"""Reusable page chrome: headers, KPI cards, charts and tables."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

import pandas as pd
import plotly.graph_objects as go
import streamlit as st
from lib import db
from lib.filter import REFRESH_CHOICES


@dataclass(frozen=True)
class Kpi:
    """One headline metric rendered as a Streamlit metric card."""

    label: str
    value: str
    delta: str | None = None
    delta_good: bool | None = None


def page_header(title: str, subtitle: str, icon: str = "🏦") -> None:
    """Page title block with icon and one-line subtitle."""
    st.title(f"{icon} {title}")
    st.caption(subtitle)
    st.divider()


def auto_fragment(fn):
    """Re-run the wrapped render function on the sidebar auto-refresh interval."""
    interval = st.session_state.get("refresh_seconds", 0)
    return st.fragment(run_every=interval or None)(fn)


def live_badge() -> None:
    """Show connection freshness next to the page title."""
    last = db.last_success_at()
    stamp = last.astimezone().strftime("%H:%M:%S") if last else "–"
    col1, col2 = st.columns([1, 4])
    with col1:
        st.success("● Live", icon="☁️")
    with col2:
        st.caption(f"Databricks marts · last query {stamp}")


def kpi_cards(metrics: list[Kpi], *, columns: int = 4) -> None:
    """Render KPI metric cards in equal-width columns."""
    for offset in range(0, len(metrics), columns):
        row = metrics[offset : offset + columns]
        cols = st.columns(len(row))
        for col, metric in zip(cols, row, strict=True):
            with col:
                st.metric(
                    metric.label,
                    metric.value,
                    metric.delta,
                    delta_color="inverse" if metric.delta_good is False else "normal",
                )


def section(title: str) -> None:
    """Sub-section heading."""
    st.markdown(f"#### {title}")


def chart(fig: go.Figure, *, caption: str | None = None) -> None:
    """Render a Plotly figure full-width with a stripped toolbar."""
    st.plotly_chart(
        fig,
        width="stretch",
        config={
            "displaylogo": False,
            "modeBarButtonsToRemove": ["lasso2d", "select2d"],
        },
    )
    if caption:
        st.caption(caption)


def two_charts(left: go.Figure, right: go.Figure) -> None:
    """Render two figures side by side."""
    col1, col2 = st.columns(2)
    with col1:
        chart(left)
    with col2:
        chart(right)


def table(
    df: pd.DataFrame,
    *,
    money_cols: tuple[str, ...] = (),
    pct_cols: tuple[str, ...] = (),
    int_cols: tuple[str, ...] = (),
    height: int = 380,
) -> None:
    """Sortable dataframe with numeric columns coerced for Streamlit formatting."""
    display = df.copy()
    for col in money_cols:
        if col in display.columns:
            display[col] = pd.to_numeric(display[col], errors="coerce")
    for col in pct_cols:
        if col in display.columns:
            display[col] = pd.to_numeric(display[col], errors="coerce")
    for col in int_cols:
        if col in display.columns:
            display[col] = pd.to_numeric(display[col], errors="coerce").astype("Int64")
    config = {}
    for col in money_cols:
        if col in display.columns:
            config[col] = st.column_config.NumberColumn(
                f"{col.replace('_', ' ').title()} (₹)", format="₹ %.2f"
            )
    for col in pct_cols:
        if col in display.columns:
            config[col] = st.column_config.NumberColumn(
                f"{col.replace('_', ' ').title()} (%)", format="%.2f"
            )
    for col in int_cols:
        if col in display.columns:
            config[col] = st.column_config.NumberColumn(
                col.replace("_", " ").title(), format="%d"
            )
    st.dataframe(
        display,
        height=height,
        width="stretch",
        hide_index=True,
        column_config=config or None,
    )


def footer() -> None:
    """Page footer with data lineage note."""
    st.divider()
    refreshed = st.session_state.get("refreshed_at")
    stamp = (
        refreshed.strftime("%d %b %Y %H:%M")
        if isinstance(refreshed, datetime)
        else datetime.now(UTC).astimezone().strftime("%d %b %Y %H:%M")
    )
    st.caption(
        f"Banking Delta Lakehouse · Databricks `{db.setting('DATABRICKS_CATALOG', 'main')}.marts` · "
        f"rendered {stamp} · auto-refresh {st.session_state.get('refresh_seconds', REFRESH_CHOICES['Off'])}s"
    )
