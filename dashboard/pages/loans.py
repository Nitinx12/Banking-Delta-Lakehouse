"""Loan portfolio: mix, repayment health and outstanding principal."""

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
from helpers.marts import load_loan_portfolio
from helpers.plotly_template import register
from helpers.theme import fmt_inr, fmt_int, fmt_pct
from lib import charts
from lib.filter import apply_multiselect, multiselect_all, render_sidebar

st.set_page_config(
    page_title="Banking Delta Lakehouse · Loans",
    page_icon="💳",
    layout="wide",
    initial_sidebar_state="expanded",
)
register()
render_sidebar()

page_header(
    "Loan Portfolio",
    "mart_loan_portfolio — aggregates by type, status, amount band, term band and vintage.",
    "💳",
)
live_badge()

base = load_loan_portfolio()
if base.empty:
    st.warning(
        "mart_loan_portfolio is empty — run the pipeline and publish_marts first."
    )
    st.stop()


def _options(column: str) -> list[str]:
    if column not in base.columns:
        return []
    return sorted(base[column].dropna().astype(str).unique())


with st.sidebar:
    st.markdown("### Portfolio filters")
    loan_type = multiselect_all("Loan type", _options("loan_type"), key="l_type")
    status = multiselect_all("Status", _options("status"), key="l_status")
    amount_band = multiselect_all(
        "Amount band", _options("loan_amount_band"), key="l_amount"
    )
    term_band = multiselect_all("Term band", _options("term_band"), key="l_term")
    years = _options("start_year")
    start_year = multiselect_all("Start year", years, key="l_year")

scoped = base.copy()
for column, chosen in (
    ("loan_type", loan_type),
    ("status", status),
    ("loan_amount_band", amount_band),
    ("term_band", term_band),
    ("start_year", start_year),
):
    scoped = apply_multiselect(scoped, column, chosen)


def _sum(df: pd.DataFrame, column: str) -> float:
    """Numeric sum of a possibly Decimal column."""
    return float(pd.to_numeric(df[column], errors="coerce").fillna(0).sum())


@auto_fragment
def body() -> None:
    """Live section: re-queries Databricks on the auto-refresh interval."""
    df = scoped
    if df.empty:
        st.warning("No portfolio rows match the current filters.")
        return

    total_amount = _sum(df, "total_loan_amount")
    total_paid = _sum(df, "total_paid")
    outstanding = _sum(df, "estimated_outstanding_principal")
    late_rate = (
        100.0 * _sum(df, "late_payments") / _sum(df, "payment_count")
        if _sum(df, "payment_count")
        else 0.0
    )
    st.caption(f"{len(df):,} portfolio slices in scope")
    section("Portfolio snapshot")
    kpi_cards(
        [
            Kpi("Loans", fmt_int(_sum(df, "loan_count"))),
            Kpi("Sanctioned", fmt_inr(total_amount, 1)),
            Kpi("Collected", fmt_inr(total_paid, 1)),
            Kpi("Outstanding", fmt_inr(outstanding, 1)),
        ]
    )
    kpi_cards(
        [
            Kpi("Interest earned", fmt_inr(_sum(df, "interest_paid"), 1)),
            Kpi("Late payment rate", fmt_pct(late_rate), delta_good=False),
            Kpi("Payments", fmt_int(_sum(df, "payment_count"))),
            Kpi("Late payments", fmt_int(_sum(df, "late_payments")), delta_good=False),
        ]
    )

    section("Portfolio mix")
    two_charts(
        charts.treemap(
            df,
            ["loan_type", "status"],
            values="total_loan_amount",
            title="Sanctioned amount by loan type and status",
        ),
        charts.bars(
            df.groupby("status", dropna=False)["loan_count"].sum().reset_index(),
            "status",
            "loan_count",
            title="Loan count by status",
        ),
    )

    section("Amount & term bands")
    two_charts(
        charts.bars(
            df.groupby("loan_amount_band", dropna=False)["total_loan_amount"]
            .sum()
            .reset_index(),
            "loan_amount_band",
            "total_loan_amount",
            money=True,
            title="Sanctioned amount by band",
        ),
        charts.bars(
            df.groupby("term_band", dropna=False)["loan_count"].sum().reset_index(),
            "term_band",
            "loan_count",
            title="Loans by term band",
        ),
    )

    section("Vintage performance")
    vintage = (
        df.groupby("start_year", dropna=False)
        .agg(
            total_loan_amount=("total_loan_amount", "sum"),
            total_paid=("total_paid", "sum"),
            estimated_outstanding_principal=("estimated_outstanding_principal", "sum"),
            loan_count=("loan_count", "sum"),
        )
        .reset_index()
        .sort_values("start_year")
    )
    for column in (
        "total_loan_amount",
        "total_paid",
        "estimated_outstanding_principal",
    ):
        vintage[column] = pd.to_numeric(vintage[column], errors="coerce")
    chart(
        charts.line(
            vintage,
            "start_year",
            ["total_loan_amount", "total_paid", "estimated_outstanding_principal"],
            money=True,
            title="Disbursed vs collected vs outstanding by vintage",
        )
    )

    section("Risk lens")
    risk = (
        df.groupby("loan_type", dropna=False)
        .agg(
            late_payment_rate_pct=("late_payment_rate_pct", "mean"),
            avg_interest_rate=("avg_interest_rate", "mean"),
            loan_count=("loan_count", "sum"),
        )
        .reset_index()
    )
    two_charts(
        charts.bars(
            risk,
            "loan_type",
            "late_payment_rate_pct",
            title="Avg late payment rate by loan type",
            color_discrete_sequence=["#EF4444"],
        ),
        charts.scatter(
            df.assign(
                avg_interest_rate=pd.to_numeric(
                    df["avg_interest_rate"], errors="coerce"
                ),
                late_payment_rate_pct=pd.to_numeric(
                    df["late_payment_rate_pct"], errors="coerce"
                ),
                loan_count=pd.to_numeric(df["loan_count"], errors="coerce"),
            ),
            x="avg_interest_rate",
            y="late_payment_rate_pct",
            color="loan_type",
            size="loan_count",
            title="Interest rate vs late payment rate (bubble = loans)",
        ),
    )

    section("Detail")
    show_cols = [
        c
        for c in (
            "loan_type",
            "status",
            "loan_amount_band",
            "term_band",
            "start_year",
            "loan_count",
            "total_loan_amount",
            "avg_loan_amount",
            "avg_interest_rate",
            "payment_count",
            "total_paid",
            "interest_paid",
            "late_payment_rate_pct",
            "estimated_outstanding_principal",
        )
        if c in df.columns
    ]
    table(
        df[show_cols].sort_values("total_loan_amount", ascending=False).head(200),
        money_cols=tuple(
            c
            for c in (
                "total_loan_amount",
                "avg_loan_amount",
                "total_paid",
                "interest_paid",
                "estimated_outstanding_principal",
            )
            if c in show_cols
        ),
        pct_cols=tuple(
            c for c in ("late_payment_rate_pct", "avg_interest_rate") if c in show_cols
        ),
        int_cols=tuple(
            c for c in ("loan_count", "payment_count", "start_year") if c in show_cols
        ),
        height=420,
    )


body()
footer()
