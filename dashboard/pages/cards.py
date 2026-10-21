"""Cards & fraud: spend trends, fraud hotspots and merchant risk."""

from __future__ import annotations

import pandas as pd
import streamlit as st
from helpers.components import (
    Kpi,
    auto_fragment,
    chart,
    footer,
    kpi_cards,
    live_badge,
    page_header,
    section,
    table,
    two_charts,
)
from helpers.marts import load_card_fraud
from helpers.plotly_template import register
from helpers.theme import DIVERGING, fmt_inr, fmt_int, fmt_pct
from lib import charts
from lib.filter import (
    apply_month_range,
    apply_multiselect,
    month_range,
    multiselect_all,
    render_sidebar,
)

st.set_page_config(
    page_title="Banking Delta Lakehouse · Cards",
    page_icon="💳",
    layout="wide",
    initial_sidebar_state="expanded",
)
register()
render_sidebar()

page_header(
    "Cards & Fraud",
    "mart_card_fraud — spend and fraud by month, card attributes and merchant category.",
    "💳",
)
live_badge()

base = load_card_fraud()
if base.empty:
    st.warning("mart_card_fraud is empty — run the pipeline and publish_marts first.")
    st.stop()


def _options(column: str) -> list[str]:
    if column not in base.columns:
        return []
    return sorted(base[column].dropna().astype(str).unique())


with st.sidebar:
    st.markdown("### Card filters")
    card_type = multiselect_all("Card type", _options("card_type"), key="f_type")
    card_category = multiselect_all(
        "Card category", _options("card_category"), key="f_category"
    )
    card_tier = multiselect_all("Card tier", _options("card_tier"), key="f_tier")
    merchant_category = multiselect_all(
        "Merchant category", _options("merchant_category"), key="f_merchant"
    )

scoped = base.copy()
for column, chosen in (
    ("card_type", card_type),
    ("card_category", card_category),
    ("card_tier", card_tier),
    ("merchant_category", merchant_category),
):
    scoped = apply_multiselect(scoped, column, chosen)

bounds = month_range(base)


def _sum(df: pd.DataFrame, column: str) -> float:
    """Numeric sum of a possibly Decimal column."""
    return float(pd.to_numeric(df[column], errors="coerce").fillna(0).sum())


@auto_fragment
def body() -> None:
    """Live section: re-queries Databricks on the auto-refresh interval."""
    df = apply_month_range(scoped, bounds)
    if df.empty:
        st.warning("No card rows match the current filters.")
        return

    spend = _sum(df, "total_amount")
    fraud_amount = _sum(df, "fraud_amount")
    txn_count = _sum(df, "txn_count")
    fraud_rate = 100.0 * _sum(df, "fraud_txn_count") / txn_count if txn_count else 0.0
    st.caption(f"{len(df):,} monthly slices in scope")
    section("Card snapshot")
    kpi_cards(
        [
            Kpi("Card spend", fmt_inr(spend, 1)),
            Kpi("Transactions", fmt_int(txn_count)),
            Kpi("Fraud amount", fmt_inr(fraud_amount, 1), delta_good=False),
            Kpi("Fraud rate", fmt_pct(fraud_rate, 3), delta_good=False),
        ]
    )

    monthly = (
        df.groupby("month_start", sort=True)
        .agg(
            total_amount=("total_amount", "sum"),
            fraud_amount=("fraud_amount", "sum"),
            fraud_rate_pct=("fraud_rate_pct", "mean"),
        )
        .reset_index()
    )
    for column in ("total_amount", "fraud_amount", "fraud_rate_pct"):
        monthly[column] = pd.to_numeric(monthly[column], errors="coerce")

    section("Spend & fraud trend")
    chart(
        charts.line(
            monthly,
            "month_start",
            ["total_amount"],
            secondary_y=["fraud_amount"],
            money=True,
            title="Card spend vs fraud amount",
        )
    )
    chart(
        charts.line(
            monthly,
            "month_start",
            ["fraud_rate_pct"],
            title="Monthly fraud rate (%)",
            hover="%{y:.3f}%",
            height=300,
        )
    )

    section("Where fraud concentrates")
    two_charts(
        charts.treemap(
            df,
            ["merchant_category", "card_type"],
            values="total_amount",
            color="fraud_rate_pct",
            color_agg="mean",
            color_continuous_scale=DIVERGING,
            title="Spend by merchant & card type (shade = fraud rate)",
        ),
        charts.bars(
            df.groupby("card_type", dropna=False)["fraud_rate_pct"]
            .mean()
            .reset_index(),
            "card_type",
            "fraud_rate_pct",
            title="Avg fraud rate by card type",
            color_discrete_sequence=["#EF4444"],
        ),
    )

    section("Card mix")
    tier_spend = (
        df.groupby("card_tier", dropna=False)["total_amount"].sum().reset_index()
    )
    category_spend = (
        df.groupby("card_category", dropna=False)["total_amount"].sum().reset_index()
    )
    two_charts(
        charts.donut(
            tier_spend["card_tier"].fillna("Unknown"),
            tier_spend["total_amount"],
            title="Spend by card tier",
        ),
        charts.donut(
            category_spend["card_category"].fillna("Unknown"),
            category_spend["total_amount"],
            title="Spend by card category",
        ),
    )

    section("Merchant risk matrix")
    pivot = df.pivot_table(
        index="card_tier",
        columns="merchant_category",
        values="fraud_rate_pct",
        aggfunc="mean",
        dropna=True,
    )
    if not pivot.empty:
        chart(
            charts.heatmap(
                pivot,
                title="Fraud rate % by tier × merchant category",
                text_template=".2f",
                height=360,
            )
        )
    volume_pivot = df.pivot_table(
        index="card_tier",
        columns="merchant_category",
        values="txn_count",
        aggfunc="sum",
        dropna=True,
    )
    if not volume_pivot.empty:
        chart(
            charts.heatmap(
                volume_pivot,
                title="Transaction count by tier × merchant category",
                height=360,
            )
        )

    section("Detail")
    show_cols = [
        c
        for c in (
            "month_start",
            "card_type",
            "card_category",
            "card_tier",
            "merchant_category",
            "txn_count",
            "active_cards",
            "total_amount",
            "avg_txn_amount",
            "fraud_txn_count",
            "fraud_amount",
            "fraud_rate_pct",
        )
        if c in df.columns
    ]
    table(
        df[show_cols].sort_values("fraud_amount", ascending=False).head(200),
        money_cols=tuple(
            c
            for c in ("total_amount", "avg_txn_amount", "fraud_amount")
            if c in show_cols
        ),
        pct_cols=("fraud_rate_pct",) if "fraud_rate_pct" in show_cols else (),
        int_cols=tuple(
            c
            for c in ("txn_count", "active_cards", "fraud_txn_count")
            if c in show_cols
        ),
        height=420,
    )


body()
footer()
