"""Customer 360: segments, products held, income, credit and activity."""

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
from helpers.marts import load_customer_360
from helpers.plotly_template import register
from helpers.theme import fmt_inr, fmt_int
from lib import charts
from lib.filter import apply_multiselect, month_range, multiselect_all, render_sidebar

st.set_page_config(
    page_title="Banking Delta · Customers",
    page_icon="👥",
    layout="wide",
    initial_sidebar_state="expanded",
)
register()
render_sidebar()

page_header(
    "Customers",
    "mart_customer_360 — one row per customer with products, activity and service history.",
    "👥",
)
live_badge()

base = load_customer_360()
if base.empty:
    st.warning("mart_customer_360 is empty — run the pipeline and publish_marts first.")
    st.stop()


def _options(column: str) -> list[str]:
    """Sorted distinct values for a categorical filter."""
    if column not in base.columns:
        return []
    return sorted(base[column].dropna().astype(str).unique())


with st.sidebar:
    st.markdown("### Customer filters")
    gender = multiselect_all("Gender", _options("gender"), key="c_gender")
    state = multiselect_all("State", _options("state"), key="c_state")
    income_band = multiselect_all(
        "Income band", _options("income_band"), key="c_income"
    )
    credit_band = multiselect_all(
        "Credit band", _options("credit_band"), key="c_credit"
    )
    age_band = multiselect_all("Age band", _options("age_band"), key="c_age")

scoped = base.copy()
for column, chosen in (
    ("gender", gender),
    ("state", state),
    ("income_band", income_band),
    ("credit_band", credit_band),
    ("age_band", age_band),
):
    scoped = apply_multiselect(scoped, column, chosen)

income_bounds = month_range(base, "join_date", "Joined between")


@auto_fragment
def body() -> None:
    """Live section: re-queries Databricks on the auto-refresh interval."""
    df = scoped.copy()
    joined = (
        df["join_date"].dt.tz_localize(None)
        if df["join_date"].dt.tz is not None
        else df["join_date"]
    )
    df = df.loc[(joined >= income_bounds[0]) & (joined < income_bounds[1])].copy()
    if df.empty:
        st.warning("No customers match the current filters.")
        return

    avg_credit = pd.to_numeric(df["credit_score"], errors="coerce").mean()
    st.caption(f"{len(df):,} customers in scope")
    section("Snapshot")
    kpi_cards(
        [
            Kpi("Customers", fmt_int(len(df))),
            Kpi(
                "Avg credit score",
                f"{avg_credit:,.0f}" if pd.notna(avg_credit) else "–",
            ),
            Kpi(
                "Total loan exposure",
                fmt_inr(
                    pd.to_numeric(df["total_loan_amount"], errors="coerce").sum(), 1
                ),
            ),
            Kpi(
                "Avg products held",
                f"{pd.to_numeric(df['products_held'], errors='coerce').mean():.2f}"
                if "products_held" in df
                else "–",
            ),
        ]
    )

    section("Where customers are")
    chart(
        charts.treemap(
            df.assign(_one=1),
            ["state", "age_band"],
            values="_one",
            color="credit_score",
            color_agg="mean",
            title="Customers by state and age band (shade = avg credit score)",
        ),
        caption="Counts are derived by grouping the customer grain in the browser.",
    )

    col1, col2 = st.columns(2)
    with col1:
        gender_split = (
            df.groupby("gender", dropna=False).size().reset_index(name="customers")
        )
        chart(
            charts.donut(
                gender_split["gender"].fillna("Unknown"),
                gender_split["customers"],
                title="Gender split",
            )
        )
    with col2:
        credit_split = (
            df.groupby("credit_band", dropna=False).size().reset_index(name="customers")
        )
        chart(
            charts.donut(
                credit_split["credit_band"].fillna("Unknown"),
                credit_split["customers"],
                title="Credit band split",
            )
        )

    section("Products & money")
    two_charts(
        charts.bars(
            df.groupby("income_band", dropna=False)
            .size()
            .reset_index(name="customers"),
            "income_band",
            "customers",
            title="Customers by income band",
        ),
        charts.bars(
            df.groupby("occupation", dropna=False)
            .size()
            .reset_index(name="customers")
            .sort_values("customers", ascending=False)
            .head(10),
            "occupation",
            "customers",
            horizontal=True,
            title="Top occupations",
        ),
    )

    two_charts(
        charts.bars(
            df.groupby("products_held", dropna=False)
            .size()
            .reset_index(name="customers"),
            "products_held",
            "customers",
            title="Products held distribution",
        ),
        charts.scatter(
            df.assign(
                annual_income=pd.to_numeric(df["annual_income"], errors="coerce")
            ),
            x="annual_income",
            y="total_loan_amount",
            color="credit_band" if "credit_band" in df.columns else None,
            size="products_held" if "products_held" in df.columns else None,
            log_x=True,
            money_y=True,
            title="Income vs loan exposure",
        ),
    )

    section("Activity")
    activity = df.sort_values("txn_amount", ascending=False).head(15)
    chart(
        charts.bars(
            activity,
            "customer_name",
            "txn_amount",
            horizontal=True,
            money=True,
            title="Top 15 customers by transaction value",
        ),
        caption="Names shown only for the highest-activity customers in scope.",
    )

    section("Detail")
    show_cols = [
        c
        for c in (
            "customer_name",
            "state",
            "age_band",
            "occupation",
            "income_band",
            "credit_score",
            "credit_band",
            "products_held",
            "total_accounts",
            "total_cards",
            "total_loans",
            "total_loan_amount",
            "txn_count",
            "txn_amount",
            "card_spend",
            "total_tickets",
            "avg_satisfaction_score",
        )
        if c in df.columns
    ]
    table(
        df[show_cols].head(200),
        money_cols=tuple(
            c
            for c in ("total_loan_amount", "txn_amount", "card_spend")
            if c in show_cols
        ),
        int_cols=tuple(
            c
            for c in (
                "credit_score",
                "products_held",
                "total_accounts",
                "total_cards",
                "total_loans",
                "txn_count",
                "total_tickets",
            )
            if c in show_cols
        ),
        height=420,
    )


body()
footer()
