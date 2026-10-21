# Shared matplotlib style and figure functions for report charts.
from __future__ import annotations

import re
import statistics
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.figure import Figure

from .render import RawTeX

PALETTE: dict[str, dict[str, str]] = {
    "source": {"stroke": "#1D4ED8", "fill": "#DBEAFE"},
    "orchestration": {"stroke": "#6D28D9", "fill": "#EDE9FE"},
    "raw": {"stroke": "#C2410C", "fill": "#FFEDD5"},
    "staging": {"stroke": "#0E7490", "fill": "#CFFAFE"},
    "analytics": {"stroke": "#15803D", "fill": "#DCFCE7"},
    "marts": {"stroke": "#BE185D", "fill": "#FCE7F3"},
    "publish": {"stroke": "#A16207", "fill": "#FEF9C3"},
    "audit": {"stroke": "#475569", "fill": "#F1F5F9"},
    "ok": {"stroke": "#15803D", "fill": "#DCFCE7"},
    "warn": {"stroke": "#A16207", "fill": "#FEF9C3"},
    "bad": {"stroke": "#B91C1C", "fill": "#FEE2E2"},
    "critical": {"stroke": "#7F1D1D", "fill": "#FECACA"},
    "idle": {"stroke": "#475569", "fill": "#F1F5F9"},
}

FULL_WIDTH = 6.7
HALF_WIDTH = 3.3
HEIGHT = 2.6


def apply_style(font_dir=None) -> None:
    """Register bundled fonts when present and set the shared rcParams."""
    if font_dir is not None:
        for path in sorted(font_dir.glob("*.ttf")):
            font_manager.fontManager.addfont(str(path))
    plt.rcParams.update(
        {
            "font.family": ["Inter", "DejaVu Sans"],
            "font.size": 8.5,
            "pdf.fonttype": 42,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.edgecolor": "#475569",
            "axes.grid": True,
            "grid.color": "#E2E8F0",
            "grid.linewidth": 0.6,
            "axes.axisbelow": True,
            "savefig.bbox": "tight",
        }
    )


def _placeholder(message: str = "no data for this section") -> Figure:
    fig, ax = plt.subplots(figsize=(HALF_WIDTH, 1.0))
    ax.text(0.5, 0.5, message, ha="center", va="center", color="#475569")
    ax.set_xticks([])
    ax.set_yticks([])
    for spine in ax.spines.values():
        spine.set_visible(False)
    return fig


def _finish(fig: Figure) -> Figure:
    fig.tight_layout()
    return fig


def task_timeline(steps: list[dict[str, Any]]) -> Figure:
    """Horizontal start-to-end timeline per task, layer coloured."""
    done = [s for s in steps if s.get("duration_s") is not None]
    if not done:
        return _placeholder()
    fig, ax = plt.subplots(figsize=(FULL_WIDTH, HEIGHT))
    for index, step in enumerate(reversed(done)):
        colour = PALETTE.get(str(step.get("layer")), PALETTE["idle"])["stroke"]
        duration = float(step["duration_s"])
        ax.barh(index, duration, left=0, color=colour, height=0.6)
        ax.text(duration, index, f" {step['name']}", va="center", fontsize=7)
    ax.set_yticks([])
    ax.set_xlabel("seconds from run start")
    return _finish(fig)


def volumes_dumbbell(tables: list[dict[str, Any]], median_rows: int | None) -> Figure:
    """Rows landed today against the trailing median per table."""
    landed = [t for t in tables if t.get("rows_landed") is not None]
    if not landed:
        return _placeholder()
    fig, ax = plt.subplots(figsize=(FULL_WIDTH, HEIGHT))
    for index, table in enumerate(reversed(landed)):
        value = int(table["rows_landed"])
        ax.plot([0, value], [index, index], color="#CBD5E1", linewidth=2)
        ax.scatter([value], [index], color="#C2410C", s=18, zorder=3)
        ax.text(value, index, f" {value:,}", va="center", fontsize=7)
        if median_rows is not None:
            ax.axvline(median_rows, color="#475569", linewidth=0.6, linestyle="--")
    ax.set_yticks([])
    ax.set_xlabel("rows landed")
    return _finish(fig)


def layer_rows(tables: list[dict[str, Any]]) -> Figure:
    """Rows touched per layer in this run."""
    per_layer: dict[str, int] = {}
    for table in tables:
        rows = table.get("rows_landed") or 0
        per_layer[table["layer"]] = per_layer.get(table["layer"], 0) + int(rows)
    if not per_layer:
        return _placeholder()
    fig, ax = plt.subplots(figsize=(HALF_WIDTH, HEIGHT))
    layers = sorted(per_layer)
    colours = [PALETTE.get(layer, PALETTE["idle"])["stroke"] for layer in layers]
    ax.bar(layers, [per_layer[layer] for layer in layers], color=colours)
    ax.set_ylabel("rows landed")
    plt.setp(ax.get_xticklabels(), rotation=20, ha="right")
    return _finish(fig)


def dq_heatmap(dq: list[dict[str, Any]]) -> Figure:
    """Check by layer matrix with the status word in each cell."""
    if not dq:
        return _placeholder()
    layers = sorted({row["layer"] for row in dq})
    scripts = sorted({row["script_name"] for row in dq})
    fig, ax = plt.subplots(figsize=(FULL_WIDTH, max(1.2, 0.45 * len(scripts) + 1)))
    for row_index, script in enumerate(scripts):
        for column_index, layer in enumerate(layers):
            match = next(
                (r for r in dq if r["layer"] == layer and r["script_name"] == script),
                None,
            )
            status = match["status"] if match else None
            colour = {
                "PASS": PALETTE["ok"]["fill"],
                "WARNING": PALETTE["warn"]["fill"],
                "FAIL": PALETTE["bad"]["fill"],
            }.get(status, PALETTE["idle"]["fill"])
            ax.add_patch(
                plt.Rectangle(
                    (column_index, row_index), 1, 1, facecolor=colour, edgecolor="white"
                )
            )
            ax.text(
                column_index + 0.5,
                row_index + 0.5,
                status or "n/a",
                ha="center",
                va="center",
                fontsize=7,
            )
    ax.set_xlim(0, len(layers))
    ax.set_ylim(0, len(scripts))
    ax.set_xticks([i + 0.5 for i in range(len(layers))], layers)
    ax.set_yticks([i + 0.5 for i in range(len(scripts))], scripts)
    ax.grid(False)
    return _finish(fig)


def freshness_bullet(freshness: list[dict[str, Any]]) -> Figure:
    """Table age against its window."""
    rows = [f for f in freshness if f.get("age_s") is not None]
    if not rows:
        return _placeholder()
    fig, ax = plt.subplots(figsize=(FULL_WIDTH, HEIGHT))
    for index, row in enumerate(reversed(rows)):
        age_hours = float(row["age_s"]) / 3600.0
        window_hours = _window_hours(row["window"])
        colour = (
            PALETTE["bad"]["stroke"] if row.get("breached") else PALETTE["ok"]["stroke"]
        )
        ax.barh(index, age_hours, color=colour, height=0.5)
        if window_hours:
            ax.plot(
                [window_hours, window_hours],
                [index - 0.35, index + 0.35],
                color="#475569",
                linewidth=1.2,
            )
    ax.set_yticks([])
    ax.set_xlabel("hours since last load (bar) vs window (tick)")
    return _finish(fig)


def error_categories(errors: list[dict[str, Any]]) -> Figure:
    """Horizontal bars of errors by category."""
    if not errors:
        return _placeholder()
    counts: dict[str, int] = {}
    for error in errors:
        counts[error["category"]] = counts.get(error["category"], 0) + 1
    fig, ax = plt.subplots(figsize=(HALF_WIDTH, HEIGHT))
    categories = sorted(counts)
    ax.barh(
        categories,
        [counts[c] for c in categories],
        color=[PALETTE["bad"]["stroke"]] * len(categories),
    )
    ax.set_xlabel("errors")
    return _finish(fig)


def trend_duration(trends: list[dict[str, Any]]) -> Figure:
    """Run duration over the last N runs with a median line."""
    rows = [t for t in trends if t.get("duration_s") is not None]
    if not rows:
        return _placeholder()
    fig, ax = plt.subplots(figsize=(FULL_WIDTH, HEIGHT))
    durations = [float(r["duration_s"]) for r in rows]
    ax.plot(range(len(durations)), durations, color="#1D4ED8", linewidth=1.4)
    median = statistics.median(durations)
    ax.axhline(median, color="#475569", linewidth=0.8, linestyle="--")
    for index, row in enumerate(rows):
        colour = {
            "SUCCESS": PALETTE["ok"]["stroke"],
            "PARTIAL": PALETTE["warn"]["stroke"],
            "FAILED": PALETTE["bad"]["stroke"],
        }.get(row["status"], PALETTE["idle"]["stroke"])
        ax.scatter([index], [durations[index]], color=colour, s=14, zorder=3)
    ax.set_ylabel("duration (s)")
    ax.set_xlabel("runs (oldest first)")
    return _finish(fig)


def trend_failures(trends: list[dict[str, Any]]) -> Figure:
    """Failures, retries and DQ fails per run as small multiples."""
    if not trends:
        return _placeholder()
    fig, axes = plt.subplots(1, 3, figsize=(FULL_WIDTH, 1.6))
    series = [
        ("failed", [int(t.get("failed_tables") or 0) for t in trends], "#B91C1C"),
        ("dq", [int(t.get("dq_failures") or 0) for t in trends], "#A16207"),
        (
            "status",
            [
                {"SUCCESS": 0, "PARTIAL": 1, "FAILED": 2}.get(t["status"], -1)
                for t in trends
            ],
            "#475569",
        ),
    ]
    for ax, (title, values, colour) in zip(axes, series):
        ax.bar(range(len(values)), values, color=colour, width=0.7)
        ax.set_title(title, fontsize=8)
        ax.set_xticks([])
    fig.tight_layout()
    return fig


def publish_reconcile(tables: list[dict[str, Any]]) -> Figure:
    """Source rows against landed rows per published table."""
    rows = [
        t
        for t in tables
        if t.get("rows_landed") is not None and t.get("rows_extracted") is not None
    ]
    if not rows:
        return _placeholder()
    fig, ax = plt.subplots(figsize=(FULL_WIDTH, HEIGHT))
    names = [str(t["table"]) for t in rows]
    positions = range(len(rows))
    ax.barh(
        [p - 0.15 for p in positions],
        [int(t["rows_extracted"]) for t in rows],
        height=0.3,
        color="#0E7490",
        label="source",
    )
    ax.barh(
        [p + 0.15 for p in positions],
        [int(t["rows_landed"]) for t in rows],
        height=0.3,
        color="#A16207",
        label="landed",
    )
    ax.set_yticks(list(positions), names)
    ax.legend(fontsize=7)
    return _finish(fig)


def figure_include(figure: Figure | None, name: str, figures_dir) -> RawTeX:
    """Save a figure and return the includegraphics command, or nothing."""
    if figure is None:
        return RawTeX("")
    path = figures_dir / f"{name}.pdf"
    figures_dir.mkdir(parents=True, exist_ok=True)
    figure.savefig(path)
    plt.close(figure)
    return RawTeX(rf"\includegraphics[width=\linewidth]{{figures/{name}.pdf}}")


def _window_hours(window: str) -> float | None:
    match = re.fullmatch(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", window)
    if not match:
        return None
    days, hours, minutes, seconds = (int(g or 0) for g in match.groups())
    return float(days * 24 + hours + minutes / 60.0 + seconds / 3600.0)
