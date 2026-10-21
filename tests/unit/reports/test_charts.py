"""The TeX style palette must not drift from the chart palette."""

from __future__ import annotations

import re

import pytest

from reports.scripts import charts
from reports.scripts.paths import REPORTS_DIR

pytestmark = pytest.mark.unit

_STY = (REPORTS_DIR / "template" / "bankingreport.sty").read_text(encoding="utf-8")
_COLORS = dict(re.findall(r"\\definecolor{(\w+)}{HTML}{([0-9A-Fa-f]{6})}", _STY))

_STEM_TO_STYLE = {
    "source": "src",
    "orchestration": "orch",
    "raw": "raw",
    "staging": "stag",
    "analytics": "ana",
    "marts": "mart",
    "publish": "pub",
    "audit": "audit",
    "ok": "ok",
    "warn": "warn",
    "bad": "bad",
    "critical": "crit",
    "idle": "idle",
}


def test_every_palette_entry_is_in_the_style() -> None:
    assert set(charts.PALETTE) == set(_STEM_TO_STYLE)
    for stem, colours in charts.PALETTE.items():
        prefix = _STEM_TO_STYLE[stem]
        assert (
            _COLORS[f"{prefix}stroke"].upper() == colours["stroke"].lstrip("#").upper()
        )
        assert _COLORS[f"{prefix}fill"].upper() == colours["fill"].lstrip("#").upper()


def test_figures_placeholder_when_empty() -> None:
    from matplotlib.figure import Figure

    assert isinstance(charts.task_timeline([]), Figure)
    assert isinstance(charts.volumes_dumbbell([], None), Figure)
    assert isinstance(charts.layer_rows([]), Figure)
    assert isinstance(charts.dq_heatmap([]), Figure)
    assert isinstance(charts.freshness_bullet([]), Figure)
    assert isinstance(charts.error_categories([]), Figure)
    assert isinstance(charts.trend_duration([]), Figure)
    assert isinstance(charts.trend_failures([]), Figure)
    assert isinstance(charts.publish_reconcile([]), Figure)
