"""Brand palette and number formatting shared by every page."""

from __future__ import annotations

import math
from collections.abc import Sequence
from datetime import date, datetime
from decimal import Decimal

import pandas as pd

PRIMARY = "#0071CE"
PRIMARY_DARK = "#005595"
SECONDARY = "#0F172A"
SURFACE = "#F8FAFC"

PALETTE = [
    PRIMARY,
    "#00B8A9",
    "#F6AE2D",
    "#F26419",
    "#6C4AB6",
    "#E63946",
    "#2A9D8F",
    "#457B9D",
    "#BC6C25",
    "#7209B7",
]

POSITIVE = "#10B981"
NEGATIVE = "#EF4444"
NEUTRAL = "#94A3B8"

CREDIT_SCALE = ["#F87171", "#FBBF24", "#34D399", "#10B981", "#047857"]
SEQUENTIAL = ["#EFF6FF", "#BFDBFE", "#60A5FA", "#2563EB", "#1E3A8A"]
DIVERGING = ["#DC2626", "#F87171", "#FEF3C7", "#6EE7B7", "#059669"]

Number = float | int | Decimal


def _as_float(value: Number) -> float:
    return float(value)


def fmt_int(value: Number | None) -> str:
    """Grouped integer label, e.g. 12,480."""
    if value is None:
        return "–"
    return f"{_as_float(value):,.0f}"


def fmt_inr(value: Number | None, decimals: int = 0) -> str:
    """Rupee label with Indian lakh/crore grouping, e.g. ₹12.45 Cr."""
    if value is None:
        return "–"
    number = _as_float(value)
    sign = "-" if number < 0 else ""
    number = abs(number)
    if number >= 1e7:
        return f"{sign}₹{number / 1e7:,.{decimals}f} Cr"
    if number >= 1e5:
        return f"{sign}₹{number / 1e5:,.{decimals}f} L"
    if number >= 1e3:
        return f"{sign}₹{number:,.0f}"
    return f"{sign}₹{number:,.{decimals}f}"


def fmt_pct(value: Number | None, decimals: int = 2) -> str:
    """Percentage label, e.g. 0.42%."""
    if value is None:
        return "–"
    return f"{_as_float(value):,.{decimals}f}%"


def fmt_date(value: datetime | date | pd.Timestamp | None) -> str:
    """Month label, e.g. Mar 2025."""
    if value is None or pd.isna(value):
        return "–"
    return f"{value:%b} {value:%Y}"


def si_ticks(values: Sequence[Number]) -> tuple[list[float], list[str]]:
    """Axis tick pairs using compact SI labels for large money/count series."""
    finite = [
        _as_float(v) for v in values if v is not None and not math.isnan(_as_float(v))
    ]
    if not finite:
        return [], []
    peak = max(abs(v) for v in finite) or 1.0
    if peak >= 1e9:
        scale, suffix = 1e9, "B"
    elif peak >= 1e6:
        scale, suffix = 1e6, "M"
    elif peak >= 1e3:
        scale, suffix = 1e3, "K"
    else:
        return [], []
    step = max(1, len(finite) // 8)
    tickvals = sorted({round(v / scale, 6) * scale for v in finite[::step]})
    ticktext = [f"{v / scale:,.1f}{suffix}" for v in tickvals]
    return tickvals, ticktext
