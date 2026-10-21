"""Banking Delta Lakehouse executive overview: headline KPIs and monthly trends."""

from __future__ import annotations

import pandas as pd
import streamlit as st
from helpers.components import (
    Kpi,
    auto_fragment,
    footer,
    kpi_cards,
    live_badge,
    page_header,
    section,
    two_charts,
)
from helpers.marts import load_kpi_monthly
from helpers.plotly_template import register
from helpers.theme import fmt_inr, fmt_int, fmt_pct
from lib import charts
from lib.filter import render_sidebar

st.set_page_config(
    page_title="Banking Delta Lakehouse · Overview",
    page_icon="🏦",
    layout="wide",
    initial_sidebar_state="expanded",
)
register()
interval = render_sidebar()

page_header(
    "Executive Overview",
    "Monthly bank performance published from the PostgreSQL warehouse into Databricks marts.",
    "🏦",
)
live_badge()


def _pct_change(series: pd.Series) -> float | None:
    """Month-over-month percent change of the latest value."""
    values = pd.to_numeric(series, errors="coerce").dropna()
    if len(values) < 2 or values.iloc[-2] == 0:
        return None
    return float((values.iloc[-1] - values.iloc[-2]) / values.iloc[-2] * 100)


def _delta(pct: float | None, suffix: str = "MoM") -> str | None:
    """Compact delta label for a metric card."""
    if pct is None or pd.isna(pct):
        return None
    return f"{pct:+.1f}% {suffix}"


@auto_fragment
def overview() -> None:
    """Live section: re-queries Databricks on the auto-refresh interval."""
    kpi = load_kpi_monthly()
    if kpi.empty:
        st.warning(
            "mart_kpi_monthly is empty — run the pipeline and publish_marts first."
        )
        return
    latest = kpi.iloc[-1]
    month_label = latest["month_start"].strftime("%b %Y")

    st.info(f"Latest published month: **{month_label}** · {len(kpi)} months of history")
    section(f"Headline KPIs — {month_label}")

    kpi_cards(
        [
            Kpi(
                "New customers",
                fmt_int(latest["new_customers"]),
                _delta(_pct_change(kpi["new_customers"])),
            ),
            Kpi(
                "New accounts",
                fmt_int(latest["new_accounts"]),
                _delta(_pct_change(kpi["new_accounts"])),
            ),
            Kpi(
                "Transaction value",
                fmt_inr(latest["txn_amount"], 1),
                _delta(latest.get("txn_amount_mom_pct")),
            ),
            Kpi(
                "Card spend",
                fmt_inr(latest["card_spend"], 1),
                _delta(latest.get("card_spend_mom_pct")),
            ),
        ]
    )
    kpi_cards(
        [
            Kpi(
                "Loan collections",
                fmt_inr(latest["loan_collections"], 1),
                _delta(latest.get("loan_collections_mom_pct")),
            ),
            Kpi(
                "Interest income",
                fmt_inr(latest["interest_income"], 1),
                _delta(_pct_change(kpi["interest_income"])),
            ),
            Kpi(
                "Fraud rate",
                fmt_pct(latest["fraud_rate_pct"], 3),
                _delta(_pct_change(kpi["fraud_rate_pct"])),
                delta_good=False,
            ),
            Kpi(
                "Ticket resolution",
                fmt_pct(latest["ticket_resolution_rate_pct"]),
                _delta(_pct_change(kpi["ticket_resolution_rate_pct"])),
            ),
        ]
    )

    section("Growth & activity trends")
    two_charts(
        charts.line(
            kpi,
            "month_start",
            ["txn_amount"],
            secondary_y=["card_spend"],
            money=True,
            title="Transaction value vs card spend",
        ),
        charts.area(
            kpi,
            "month_start",
            ["cumulative_customers"],
            secondary_y=["cumulative_accounts"],
            title="Cumulative customers & accounts",
        ),
    )

    section("Lending")
    two_charts(
        charts.line(
            kpi,
            "month_start",
            ["loans_disbursed"],
            secondary_y=["loan_amount_disbursed"],
            title="Loans disbursed (count vs amount)",
        ),
        charts.line(
            kpi,
            "month_start",
            ["loan_collections"],
            secondary_y=["interest_income"],
            money=True,
            title="Collections vs interest income",
        ),
    )

    section("Risk & service quality")
    two_charts(
        charts.line(
            kpi,
            "month_start",
            ["fraud_rate_pct"],
            title="Card fraud rate (%)",
            hover="%{y:.3f}%",
        ),
        charts.line(
            kpi,
            "month_start",
            ["late_payment_rate_pct"],
            secondary_y=["avg_satisfaction_score"],
            title="Late payment rate vs satisfaction",
        ),
    )
    two_charts(
        charts.bars(
            kpi,
            "month_start",
            ["tickets_opened", "tickets_resolved"],
            title="Support tickets opened vs resolved",
        ),
        charts.diverging_mom(
            kpi,
            "month_start",
            "txn_amount_mom_pct",
            title="Transaction value — month-over-month %",
        ),
    )


overview()
footer()
