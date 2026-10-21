"""KPI explorer: drill into monthly headline metrics, MoM growth and quarterly rollups."""

from __future__ import annotations

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
)
from helpers.marts import load_kpi_monthly
from helpers.plotly_template import register
from helpers.theme import fmt_inr, fmt_int
from lib import charts
from lib.filter import apply_month_range, month_range, render_sidebar

st.set_page_config(
    page_title="Banking Delta Lakehouse · KPI Explorer",
    page_icon="📈",
    layout="wide",
    initial_sidebar_state="expanded",
)
register()
render_sidebar()

METRIC_GROUPS: dict[str, dict[str, str]] = {
    "Growth": {
        "new_customers": "New customers",
        "new_accounts": "New accounts",
        "cumulative_customers": "Cumulative customers",
        "cumulative_accounts": "Cumulative accounts",
    },
    "Lending": {
        "loans_disbursed": "Loans disbursed",
        "loan_amount_disbursed": "Loan amount disbursed",
        "loan_collections": "Loan collections",
        "interest_income": "Interest income",
        "late_payment_rate_pct": "Late payment rate %",
        "loan_collections_mom_pct": "Collections MoM %",
    },
    "Transactions": {
        "txn_count": "Transaction count",
        "txn_amount": "Transaction value",
        "transacting_accounts": "Transacting accounts",
        "avg_txn_amount": "Avg ticket size",
        "txn_amount_mom_pct": "Txn value MoM %",
    },
    "Cards & fraud": {
        "card_txn_count": "Card transactions",
        "card_spend": "Card spend",
        "fraud_txn_count": "Fraud transactions",
        "fraud_amount": "Fraud amount",
        "fraud_rate_pct": "Fraud rate %",
        "card_spend_mom_pct": "Card spend MoM %",
    },
    "Support": {
        "tickets_opened": "Tickets opened",
        "tickets_resolved": "Tickets resolved",
        "ticket_resolution_rate_pct": "Resolution rate %",
        "avg_resolution_days": "Avg resolution days",
        "avg_satisfaction_score": "Avg satisfaction",
    },
}
MONEY_COLS = {
    "loan_amount_disbursed",
    "loan_collections",
    "interest_income",
    "txn_amount",
    "avg_txn_amount",
    "card_spend",
    "fraud_amount",
    "cumulative_loan_amount",
}

page_header(
    "KPI Explorer",
    "Every monthly headline metric from mart_kpi_monthly — trend, growth and quarterly view.",
    "📈",
)
live_badge()

with st.sidebar:
    st.markdown("### KPI filters")
    bounds = month_range(load_kpi_monthly())
    groups = st.multiselect(
        "Metric groups", list(METRIC_GROUPS), default=list(METRIC_GROUPS)
    )
    show_quarterly = st.checkbox("Add quarterly rollup", value=True)

picked: dict[str, str] = {}
for group in groups:
    picked.update(METRIC_GROUPS[group])


@auto_fragment
def body() -> None:
    """Live section: re-queries Databricks on the auto-refresh interval."""
    kpi = apply_month_range(load_kpi_monthly(), bounds)
    if kpi.empty:
        st.warning("No months in the selected range.")
        return
    pct_cols = {c for c in kpi.columns if c.endswith("_pct")}
    latest = kpi.iloc[-1]
    st.caption(
        f"Showing {kpi['month_start'].min():%b %Y} → {kpi['month_start'].max():%b %Y} · {len(kpi)} months"
    )

    if picked:
        section("Selected metrics")
        items = list(picked.items())
        for offset in range(0, len(items), 2):
            pair = items[offset : offset + 2]
            cols = st.columns(len(pair))
            for col, (metric_col, label) in zip(cols, pair, strict=True):
                with col:
                    money = metric_col in MONEY_COLS
                    chart(
                        charts.line(
                            kpi,
                            "month_start",
                            [metric_col],
                            title=label,
                            money=money,
                            hover="%{y:.2f}%" if metric_col in pct_cols else None,
                            height=320,
                        )
                    )

    section("Latest month snapshot")
    kpi_cards(
        [
            Kpi("New customers", fmt_int(latest["new_customers"])),
            Kpi("Txn value", fmt_inr(latest["txn_amount"], 1)),
            Kpi("Card spend", fmt_inr(latest["card_spend"], 1)),
            Kpi("Collections", fmt_inr(latest["loan_collections"], 1)),
        ]
    )

    section("Month-over-month growth")
    mom_cols = [
        c
        for c in (
            "txn_amount_mom_pct",
            "card_spend_mom_pct",
            "loan_collections_mom_pct",
        )
        if c in kpi.columns
    ]
    if mom_cols:
        col1, col2, col3 = st.columns(3)
        for col, metric_col in zip((col1, col2, col3), mom_cols, strict=False):
            with col:
                chart(
                    charts.diverging_mom(
                        kpi,
                        "month_start",
                        metric_col,
                        title=metric_col.replace("_", " ").title(),
                        height=300,
                    )
                )
    else:
        st.caption("No MoM columns available in this range.")

    if show_quarterly:
        section("Quarterly rollup")
        quarter = kpi.copy()
        quarter["quarter_label"] = quarter["month_start"].dt.to_period("Q").astype(str)
        numeric = quarter.select_dtypes("number").columns
        rollup = (
            quarter.groupby("quarter_label", sort=True)[numeric]
            .sum(min_count=1)
            .reset_index()
        )
        pct_rollup = (
            quarter.groupby("quarter_label", sort=True)[
                [c for c in numeric if c in pct_cols]
            ]
            .mean()
            .reset_index()
        )
        col1, col2 = st.columns(2)
        with col1:
            chart(
                charts.bars(
                    rollup,
                    "quarter_label",
                    "txn_amount",
                    money=True,
                    title="Quarterly transaction value",
                )
            )
        with col2:
            if not pct_rollup.empty:
                metric_col = pct_rollup.columns[1]
                chart(
                    charts.bars(
                        pct_rollup,
                        "quarter_label",
                        metric_col,
                        title=f"Quarterly {metric_col.replace('_', ' ')}",
                    )
                )

    section("Full KPI table")
    table(
        kpi.drop(columns=[c for c in ("mart_refreshed_at",) if c in kpi.columns]),
        money_cols=tuple(c for c in MONEY_COLS if c in kpi.columns),
        pct_cols=tuple(c for c in pct_cols if c in kpi.columns),
        int_cols=tuple(
            c
            for c in kpi.columns
            if c not in MONEY_COLS
            and c not in pct_cols
            and c
            not in (
                "month_start",
                "year",
                "quarter",
                "avg_resolution_days",
                "avg_satisfaction_score",
                "avg_interest_rate",
                "avg_txn_amount",
            )
        ),
        height=420,
    )


body()
footer()
