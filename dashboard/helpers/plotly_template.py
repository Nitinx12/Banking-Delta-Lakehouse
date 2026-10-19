"""Custom Plotly template so every chart shares one banking look."""

from __future__ import annotations

import plotly.io as pio
from helpers.theme import NEUTRAL, PALETTE, SECONDARY, SURFACE

TEMPLATE_NAME = "banking"

_LAYOUT = {
    "template": "plotly_white",
    "font": {
        "family": "Segoe UI, Helvetica, Arial, sans-serif",
        "size": 13,
        "color": SECONDARY,
    },
    "title": {"font": {"size": 16, "color": SECONDARY}, "x": 0.01, "xanchor": "left"},
    "paper_bgcolor": "#FFFFFF",
    "plot_bgcolor": SURFACE,
    "colorway": PALETTE,
    "margin": {"l": 16, "r": 16, "t": 56, "b": 16},
    "hoverlabel": {"bgcolor": "#FFFFFF", "font_size": 13, "bordercolor": NEUTRAL},
    "legend": {
        "orientation": "h",
        "yanchor": "bottom",
        "y": 1.02,
        "xanchor": "left",
        "x": 0,
    },
    "xaxis": {"gridcolor": "#E2E8F0", "zeroline": False, "linecolor": NEUTRAL},
    "yaxis": {"gridcolor": "#E2E8F0", "zeroline": False, "linecolor": NEUTRAL},
    "geo": {"bgcolor": "#FFFFFF", "showland": True, "landcolor": SURFACE},
}


def register() -> None:
    """Register the shared template and make it the default."""
    pio.templates[TEMPLATE_NAME] = pio.templates["plotly_white"].update(layout=_LAYOUT)
    pio.templates.default = TEMPLATE_NAME
