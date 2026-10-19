"""Branch performance: regional comparison, league tables and efficiency."""

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
from helpers.marts import load_branch_performance
from helpers.plotly_template import register
from helpers.theme import fmt_inr, fmt_int, fmt_pct
from lib import charts
from lib.filter import apply_multiselect, multiselect_all, render_sidebar

st.set_page_config(
    page_title="Banking Delta · Branches",
    page_icon="🏛️",
    layout="wide",
    initial_sidebar_state="expanded",
)
register()
render_sidebar()

page_header(
    "Branch Performance",
    "mart_branch_performance — one row per branch with customers, staff, loans and volume.",
    "🏛️",
)
live_badge()

base = load_branch_performance()
if base.empty:
    st.warning(
        "mart_branch_performance is empty — run the pipeline and publish_marts first."
    )
    st.stop()


def _options(column: str) -> list[str]:
    if column not in base.columns:
        return []
    return sorted(base[column].dropna().astype(str).unique())


with st.sidebar:
    st.markdown("### Branch filters")
    region = multiselect_all("Region", _options("region"), key="b_region")
    state = multiselect_all("State", _options("state"), key="b_state")
    age_band = multiselect_all(
        "Branch age band", _options("branch_age_band"), key="b_age"
    )

scoped = base.copy()
for column, chosen in (
    ("region", region),
    ("state", state),
    ("branch_age_band", age_band),
):
    scoped = apply_multiselect(scoped, column, chosen)


def _sum(df: pd.DataFrame, column: str) -> float:
    """Numeric sum of a possibly Decimal column."""
    return float(pd.to_numeric(df[column], errors="coerce").fillna(0).sum())


def _numeric(df: pd.DataFrame, column: str) -> pd.Series:
    """Numeric view of a possibly Decimal column."""
    return pd.to_numeric(df[column], errors="coerce")


@auto_fragment
def body() -> None:
    """Live section: re-queries Databricks on the auto-refresh interval."""
    df = scoped
    if df.empty:
        st.warning("No branches match the current filters.")
        return

    txn_amount = _sum(df, "txn_amount")
    customers = _sum(df, "total_customers")
    collected = _sum(df, "total_loan_collected")
    late_rate = _numeric(df, "late_payment_rate_pct").mean()
    st.caption(f"{len(df):,} branches in scope")
    section("Network snapshot")
    kpi_cards(
        [
            Kpi("Branches", fmt_int(len(df))),
            Kpi("Customers", fmt_int(customers)),
            Kpi("Transaction value", fmt_inr(txn_amount, 1)),
            Kpi("Loan collections", fmt_inr(collected, 1)),
        ]
    )
    kpi_cards(
        [
            Kpi("Accounts", fmt_int(_sum(df, "total_accounts"))),
            Kpi("Employees", fmt_int(_sum(df, "employee_count"))),
            Kpi(
                "Avg accounts / employee",
                f"{_numeric(df, 'accounts_per_employee').mean():.1f}",
            ),
            Kpi("Late payment rate", fmt_pct(late_rate), delta_good=False),
        ]
    )

    section("Branch league table")
    top = (
        df.assign(txn_amount_num=_numeric(df, "txn_amount"))
        .sort_values("txn_amount_num", ascending=False)
        .head(15)
    )
    chart(
        charts.bars(
            top,
            "branch_name",
            "txn_amount_num",
            horizontal=True,
            money=True,
            title="Top 15 branches by transaction value",
        ),
    )

    section("Regional picture")
    region_df = (
        df.groupby("region", dropna=False)
        .agg(
            txn_amount=("txn_amount", "sum"),
            total_customers=("total_customers", "sum"),
            total_loan_collected=("total_loan_collected", "sum"),
            total_loans=("total_loans", "sum"),
            branch_count=("branch_id", "count"),
        )
        .reset_index()
    )
    for column in (
        "txn_amount",
        "total_customers",
        "total_loan_collected",
        "total_loans",
    ):
        region_df[column] = pd.to_numeric(region_df[column], errors="coerce")
    two_charts(
        charts.bars(
            region_df,
            "region",
            "txn_amount",
            money=True,
            title="Transaction value by region",
        ),
        charts.bars(
            region_df,
            "region",
            ["total_customers", "total_loans"],
            title="Customers vs loans by region",
        ),
    )

    chart(
        charts.treemap(
            df.assign(txn_amount_num=_numeric(df, "txn_amount")),
            ["region", "state", "branch_name"],
            values="txn_amount_num",
            title="Transaction value: region → state → branch",
            height=460,
        )
    )

    section("Efficiency & risk")
    two_charts(
        charts.scatter(
            df.assign(
                total_customers_num=_numeric(df, "total_customers"),
                txn_amount_num=_numeric(df, "txn_amount"),
                employee_count_num=_numeric(df, "employee_count"),
            ),
            x="total_customers_num",
            y="txn_amount_num",
            color="region",
            size="employee_count_num",
            money_y=True,
            title="Customers vs volume (bubble = staff)",
        ),
        charts.scatter(
            df.assign(
                avg_salary_num=_numeric(df, "avg_salary"),
                accounts_per_employee_num=_numeric(df, "accounts_per_employee"),
                total_accounts_num=_numeric(df, "total_accounts"),
            ),
            x="avg_salary_num",
            y="accounts_per_employee_num",
            color="region",
            size="total_accounts_num",
            money_x=True,
            title="Salary cost vs accounts per employee",
        ),
    )

    worst = (
        df.assign(late_num=_numeric(df, "late_payment_rate_pct"))
        .query("total_loans > 0")
        .sort_values("late_num", ascending=False)
        .head(10)
    )
    if not worst.empty:
        chart(
            charts.bars(
                worst,
                "branch_name",
                "late_num",
                horizontal=True,
                title="Top 10 branches by late payment rate",
                color_discrete_sequence=["#EF4444"],
            )
        )

    section("Detail")
    show_cols = [
        c
        for c in (
            "branch_name",
            "city",
            "state",
            "region",
            "branch_age_band",
            "total_customers",
            "total_accounts",
            "employee_count",
            "total_loans",
            "total_loan_amount",
            "total_loan_collected",
            "late_payment_rate_pct",
            "txn_count",
            "txn_amount",
            "accounts_per_employee",
        )
        if c in df.columns
    ]
    table(
        df[show_cols],
        money_cols=tuple(
            c
            for c in ("total_loan_amount", "total_loan_collected", "txn_amount")
            if c in show_cols
        ),
        pct_cols=("late_payment_rate_pct",)
        if "late_payment_rate_pct" in show_cols
        else (),
        int_cols=tuple(
            c
            for c in (
                "total_customers",
                "total_accounts",
                "employee_count",
                "total_loans",
                "txn_count",
            )
            if c in show_cols
        ),
        height=420,
    )


body()
footer()
