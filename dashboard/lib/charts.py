"""Plotly figure builders so every chart shares one banking look."""

from __future__ import annotations

from collections.abc import Sequence

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
from helpers.theme import (
    DIVERGING,
    NEGATIVE,
    NEUTRAL,
    PALETTE,
    POSITIVE,
    SEQUENTIAL,
    Number,
    si_ticks,
)

MONEY_HOVER = "%{y:,.0f}"
INT_HOVER = "%{y:,.0f}"
PCT_HOVER = "%{y:.2f}"


def _finish(
    fig: go.Figure,
    *,
    height: int = 380,
    title: str = "",
    hovermode: str | None = None,
) -> go.Figure:
    """Apply the shared frame: height, margins and hover mode."""
    fig.update_layout(
        height=height,
        margin={"l": 16, "r": 16, "t": 56 if title else 32, "b": 16},
        title=title,
        hovermode=hovermode or "closest",
        showlegend=False,
    )
    fig.update_xaxes(showgrid=False)
    return fig


def _money_axis(
    fig: go.Figure, axis: str = "y", series: Sequence[Number] | None = None
) -> None:
    """Format one axis for rupee values with compact tick labels."""
    fig.update_layout(**{f"{axis}axis_tickprefix": "₹"})
    fig.update_layout(**{f"{axis}axis_tickformat": ",.0f"})
    if series is not None:
        tickvals, ticktext = si_ticks(series)
        if tickvals:
            fig.update_layout(
                **{f"{axis}axis_tickvals": tickvals, f"{axis}axis_ticktext": ticktext}
            )


def _hover(money: bool, custom: str | None = None) -> str:
    """Hovertemplate body for money or plain counts."""
    return custom or (MONEY_HOVER if money else INT_HOVER)


def line(
    df: pd.DataFrame,
    x: str,
    y: list[str],
    *,
    title: str = "",
    secondary_y: list[str] | None = None,
    area: bool = False,
    money: bool = False,
    height: int = 380,
    hover: str | None = None,
) -> go.Figure:
    """Multi-series line (optionally dual-axis) over a shared x column."""
    body = _hover(money, hover)
    fig = go.Figure()
    for i, col in enumerate(y):
        name = col.replace("_", " ").title()
        trace: dict = {
            "type": "scatter",
            "x": df[x],
            "y": df[col],
            "name": name,
            "mode": "lines+markers",
            "line": {"width": 3, "color": PALETTE[i % len(PALETTE)]},
            "hovertemplate": f"{name}<br>%{{x|%b %Y}}<br>{body}<extra></extra>",
        }
        if area:
            trace["fill"] = "tozeroy"
            trace["fillcolor"] = f"rgba({_hex_rgb(PALETTE[i % len(PALETTE)])},0.15)"
        fig.add_trace(trace)
    for i, col in enumerate(secondary_y or []):
        name = col.replace("_", " ").title()
        fig.add_trace(
            {
                "type": "scatter",
                "x": df[x],
                "y": df[col],
                "name": name,
                "yaxis": f"y{i + 2}",
                "mode": "lines+markers",
                "line": {
                    "width": 3,
                    "color": PALETTE[(i + len(y)) % len(PALETTE)],
                    "dash": "dot",
                },
                "hovertemplate": f"{name}<br>%{{x|%b %Y}}<br>{body}<extra></extra>",
            }
        )
    if money:
        _money_axis(fig, "y", list(df[y[0]].dropna()))
    if secondary_y:
        axis2: dict = {"overlaying": "y", "side": "right"}
        if money:
            axis2.update(tickprefix="₹", tickformat=",.0f")
        fig.update_layout(yaxis2=axis2)
        fig.update_layout(
            showlegend=True, legend={"orientation": "h", "y": 1.14, "x": 0}
        )
    fig.update_xaxes(title_text=x.replace("_", " ").title())
    return _finish(
        fig,
        title=title,
        height=height,
        hovermode="x unified" if len(y) + len(secondary_y or []) > 1 else "closest",
    )


def bars(
    df: pd.DataFrame,
    x: str,
    y: str | list[str],
    *,
    title: str = "",
    color: str | None = None,
    barmode: str = "group",
    horizontal: bool = False,
    money: bool = False,
    text_auto: bool = False,
    height: int = 380,
    color_discrete_sequence: list[str] | None = None,
) -> go.Figure:
    """Grouped or stacked bar chart (vertical or horizontal)."""
    y_cols = [y] if isinstance(y, str) else y
    text_kw = {"text_auto": ".0s"} if text_auto else {}
    if horizontal and len(y_cols) > 1:
        plot_df = df.melt(
            id_vars=[x] + ([color] if color else []),
            value_vars=y_cols,
            var_name="series",
            value_name="value",
        )
        fig = px.bar(
            plot_df,
            x="value",
            y=x,
            color="series" if color is None else color,
            barmode=barmode,
            orientation="h",
            color_discrete_sequence=color_discrete_sequence,
        )
        if money:
            _money_axis(fig, "x", list(plot_df["value"].dropna()))
        fig.update_layout(yaxis={"categoryorder": "total ascending"}, showlegend=True)
        fig.update_traces(hovertemplate="%{y}<br>%{x:,.0f}<extra></extra>")
        return _finish(fig, title=title, height=height)
    plot_df = df[[x] + y_cols + ([color] if color else [])]
    if horizontal:
        fig = px.bar(
            plot_df,
            x=y_cols[0] if len(y_cols) == 1 else y_cols,
            y=x,
            color=color,
            barmode=barmode,
            orientation="h",
            color_discrete_sequence=color_discrete_sequence,
            **text_kw,
        )
        if money:
            _money_axis(fig, "x", list(plot_df[y_cols[0]].dropna()))
        fig.update_layout(
            yaxis={"categoryorder": "total ascending"} if not color else {}
        )
    else:
        fig = px.bar(
            plot_df,
            x=x,
            y=y_cols[0] if len(y_cols) == 1 else y_cols,
            color=color,
            barmode=barmode,
            color_discrete_sequence=color_discrete_sequence,
            **text_kw,
        )
        if money:
            _money_axis(fig, "y", list(plot_df[y_cols[0]].dropna()))
    fig.update_traces(hovertemplate="%{x}<br>%{y:,.0f}<extra></extra>")
    fig.update_xaxes(
        tickangle=-30 if not horizontal and df[x].astype(str).str.len().max() > 8 else 0
    )
    show_legend = color is not None or len(y_cols) > 1
    fig.update_layout(showlegend=show_legend)
    return _finish(fig, title=title, height=height)


def diverging_mom(
    df: pd.DataFrame,
    x: str,
    y: str,
    *,
    title: str = "",
    height: int = 340,
) -> go.Figure:
    """Month-over-month bars coloured green when positive, red when negative."""
    values = df[y].fillna(0)
    colors = [POSITIVE if v >= 0 else NEGATIVE for v in values]
    fig = go.Figure(
        go.Bar(
            x=df[x],
            y=values,
            marker_color=colors,
            hovertemplate=f"{y}<br>%{{x|%b %Y}}<br>%{{y:+,.1f}}%<extra></extra>",
        )
    )
    fig.update_yaxes(ticksuffix="%", zeroline=True, zerolinecolor=NEUTRAL)
    return _finish(fig, title=title, height=height, hovermode="x unified")


def donut(
    labels: Sequence[str],
    values: Sequence[Number],
    *,
    title: str = "",
    height: int = 340,
    text_template: str = "%{label}<br>%{percent}",
) -> go.Figure:
    """Donut chart for part-to-whole splits."""
    fig = go.Figure(
        go.Pie(
            labels=labels,
            values=[float(v) for v in values],
            hole=0.62,
            textinfo="label+percent",
            texttemplate=text_template,
            marker={"colors": PALETTE, "line": {"color": "#FFFFFF", "width": 2}},
            hovertemplate="%{label}<br>%{value:,.0f} (%{percent})<extra></extra>",
        )
    )
    fig.update_layout(showlegend=False)
    return _finish(fig, title=title, height=height)


def treemap(
    df: pd.DataFrame,
    path: list[str],
    values: str,
    *,
    color: str | None = None,
    color_agg: str = "mean",
    color_continuous_scale: list[str] | None = None,
    title: str = "",
    height: int = 420,
) -> go.Figure:
    """Treemap sized by `values` (summed) per path, shaded by mean `color`."""
    aggregations: dict[str, str] = {values: "sum"}
    if color:
        aggregations[color] = color_agg
    path_filled = df.copy()
    for level in path:
        path_filled[level] = path_filled[level].fillna("Unknown")
    path_filled[values] = pd.to_numeric(path_filled[values], errors="coerce")
    plot_df = path_filled.groupby(path, dropna=False).agg(aggregations).reset_index()
    fig = px.treemap(
        plot_df,
        path=path,
        values=values,
        color=color,
        color_continuous_scale=color_continuous_scale or SEQUENTIAL,
        color_continuous_midpoint=None,
    )
    fig.update_traces(
        hovertemplate="%{label}<br>"
        + values.replace("_", " ").title()
        + ": %{value:,.0f}<extra></extra>"
    )
    return _finish(fig, title=title, height=height)


def scatter(
    df: pd.DataFrame,
    x: str,
    y: str,
    *,
    color: str | None = None,
    size: str | None = None,
    log_x: bool = False,
    title: str = "",
    height: int = 400,
    money_x: bool = False,
    money_y: bool = False,
) -> go.Figure:
    """Bubble scatter; point size optionally driven by a third metric."""
    fig = px.scatter(
        df,
        x=x,
        y=y,
        color=color,
        size=size,
        log_x=log_x,
        color_discrete_sequence=PALETTE,
        size_max=36,
        opacity=0.8,
    )
    fig.update_traces(marker={"line": {"width": 1, "color": "#FFFFFF"}})
    fig.update_layout(showlegend=color is not None and df[color].nunique() <= 8)
    if money_x:
        _money_axis(fig, "x", list(df[x].dropna()))
    if money_y:
        _money_axis(fig, "y", list(df[y].dropna()))
    fig.update_xaxes(title_text=x.replace("_", " ").title())
    fig.update_yaxes(title_text=y.replace("_", " ").title())
    return _finish(fig, title=title, height=height)


def heatmap(
    pivot: pd.DataFrame,
    *,
    title: str = "",
    colorscale: list[str] | None = None,
    money: bool = False,
    text_template: str = ",.0f",
    height: int = 400,
) -> go.Figure:
    """Heatmap over a pre-pivoted index x columns matrix."""
    fig = go.Figure(
        go.Heatmap(
            z=pivot.values,
            x=[str(c) for c in pivot.columns],
            y=[str(i) for i in pivot.index],
            colorscale=colorscale or SEQUENTIAL,
            colorbar={"tickformat": text_template},
            text=[
                [f"{v:{text_template}}" if not pd.isna(v) else "" for v in row]
                for row in pivot.values
            ],
            texttemplate="%{text}",
            hovertemplate="%{y}<br>%{x}<br>%{z:,.2f}<extra></extra>",
        )
    )
    fig.update_yaxes(autorange="reversed")
    fig.update_xaxes(tickangle=-30)
    if money:
        fig.update_layout(coloraxis_colorbar={"tickprefix": "₹"})
    return _finish(fig, title=title, height=height, hovermode="closest")


def funnel(
    labels: Sequence[str],
    values: Sequence[Number],
    *,
    title: str = "",
    height: int = 360,
) -> go.Figure:
    """Funnel for stage-style counts (ticket statuses, portfolio stages)."""
    fig = px.funnel(
        x=[float(v) for v in values],
        y=list(labels),
        color_discrete_sequence=PALETTE[: len(labels)],
    )
    fig.update_traces(hovertemplate="%{y}<br>%{x:,.0f}<extra></extra>")
    return _finish(fig, title=title, height=height)


def area(
    df: pd.DataFrame,
    x: str,
    y: list[str],
    *,
    title: str = "",
    secondary_y: list[str] | None = None,
    height: int = 360,
) -> go.Figure:
    """Stacked-free overlapping area chart for cumulative series."""
    fig = go.Figure()
    for i, col in enumerate(y):
        fig.add_trace(
            {
                "type": "scatter",
                "mode": "lines",
                "name": col.replace("_", " ").title(),
                "x": df[x],
                "y": df[col],
                "line": {"width": 1, "color": PALETTE[i % len(PALETTE)]},
                "fill": "tozeroy",
                "fillcolor": f"rgba({_hex_rgb(PALETTE[i % len(PALETTE)])},0.18)",
                "hovertemplate": f"{col}<br>%{{x|%b %Y}}<br>%{{y:,.0f}}<extra></extra>",
            }
        )
    for i, col in enumerate(secondary_y or []):
        fig.add_trace(
            {
                "type": "scatter",
                "mode": "lines",
                "name": col.replace("_", " ").title(),
                "x": df[x],
                "y": df[col],
                "yaxis": f"y{i + 2}",
                "line": {
                    "width": 2,
                    "color": PALETTE[(i + len(y)) % len(PALETTE)],
                    "dash": "dot",
                },
                "hovertemplate": f"{col}<br>%{{x|%b %Y}}<br>%{{y:,.0f}}<extra></extra>",
            }
        )
    if secondary_y:
        fig.update_layout(yaxis2={"overlaying": "y", "side": "right"})
    fig.update_layout(showlegend=True, legend={"orientation": "h", "y": 1.14, "x": 0})
    return _finish(fig, title=title, height=height, hovermode="x unified")


def _hex_rgb(hex_color: str) -> str:
    """Expand #RRGGBB to 'R,G,B' for rgba() strings."""
    value = hex_color.lstrip("#")
    return ",".join(str(int(value[i : i + 2], 16)) for i in (0, 2, 4))


def diverging_scale() -> list[str]:
    """Red-to-green colour scale for signed metrics."""
    return DIVERGING
