"""Typed loaders for each table in the Databricks marts schema."""

from __future__ import annotations

from decimal import Decimal

import pandas as pd
from lib.db import run_query, setting

MART_SCHEMA_DEFAULT = "marts"


def mart_schema() -> str:
    """Schema that holds the published Delta marts."""
    return setting("DATABRICKS_MARTS_SCHEMA", MART_SCHEMA_DEFAULT)


def mart_table(name: str) -> str:
    """Fully qualified mart table name: catalog.schema.table."""
    catalog = setting("DATABRICKS_CATALOG", "main")
    return f"{catalog}.{mart_schema()}.{name}"


def _cast_decimals(df: pd.DataFrame) -> pd.DataFrame:
    """Cast connector Decimal columns to float64 so pandas maths and Plotly work."""
    for column in df.columns:
        if df[column].dtype != object:
            continue
        sample = df[column].dropna().head(1)
        if not sample.empty and isinstance(sample.iloc[0], Decimal):
            df[column] = pd.to_numeric(df[column], errors="coerce")
    return df


def _sorted_month(df: pd.DataFrame, column: str = "month_start") -> pd.DataFrame:
    df[column] = pd.to_datetime(df[column])
    return df.sort_values(column).reset_index(drop=True)


def load_kpi_monthly() -> pd.DataFrame:
    """Headline bank KPIs, one row per month, oldest first."""
    df = run_query(f"SELECT * FROM {mart_table('mart_kpi_monthly')}")
    return _sorted_month(_cast_decimals(df))


def load_customer_360() -> pd.DataFrame:
    """One row per customer with product, activity and service aggregates."""
    df = _cast_decimals(run_query(f"SELECT * FROM {mart_table('mart_customer_360')}"))
    if "join_date" in df.columns:
        df["join_date"] = pd.to_datetime(df["join_date"])
    return df


def load_branch_performance() -> pd.DataFrame:
    """One row per branch with customers, staff, loans and volume."""
    return _cast_decimals(
        run_query(f"SELECT * FROM {mart_table('mart_branch_performance')}")
    )


def load_loan_portfolio() -> pd.DataFrame:
    """Loan aggregates by type, status, amount band, term band and start year."""
    df = _cast_decimals(run_query(f"SELECT * FROM {mart_table('mart_loan_portfolio')}"))
    if "start_year" in df.columns:
        df["start_year"] = df["start_year"].astype("Int64")
    return df


def load_card_fraud() -> pd.DataFrame:
    """Card spend and fraud aggregates by month, card attributes and merchant."""
    df = run_query(f"SELECT * FROM {mart_table('mart_card_fraud')}")
    return _sorted_month(_cast_decimals(df))


def load_monthly_transactions() -> pd.DataFrame:
    """Transaction volume by month, type, channel, merchant, region and state."""
    df = run_query(f"SELECT * FROM {mart_table('mart_monthly_transactions')}")
    return _sorted_month(_cast_decimals(df))


def load_support_performance() -> pd.DataFrame:
    """Ticket volumes and resolution quality by month, issue, status and segment."""
    df = run_query(f"SELECT * FROM {mart_table('mart_support_performance')}")
    return _sorted_month(_cast_decimals(df), "month_opened")
