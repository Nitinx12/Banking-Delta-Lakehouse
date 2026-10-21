# Grid layout for the TikZ pipeline flow, built from the steps list.
from __future__ import annotations

from typing import Any

ALLOWED_LAYERS = {
    "source",
    "orchestration",
    "raw",
    "staging",
    "analytics",
    "marts",
    "publish",
    "audit",
}
ALLOWED_STATES = {"ok", "warn", "bad", "idle"}

# Three extracts stacked on the left, then the gated chain to the right.
_EXTRACT_ROWS = {"extract_mongo": 2.0, "extract_databricks": 1.0, "extract_mysql": 0.0}
_CHAIN_ROWS = {
    "preflight": 5.0,
    "raw_tests": 4.0,
    "staging_load": 3.0,
    "staging_tests": 2.0,
    "analytics_load": 1.0,
    "analytics_tests": 0.0,
    "marts_load": -1.0,
    "marts_tests": -2.0,
    "publish": -3.0,
    "finalize_audit": -4.0,
}


def _fmt_duration(value: object) -> str:
    if value is None:
        return "-"
    seconds = int(value)
    if seconds < 60:
        return f"{seconds}s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {seconds:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m"


def build_flow(steps: list[dict[str, Any]]) -> dict[str, Any]:
    """Nodes and edges for the TikZ picture; unknown layers or states raise."""
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, str]] = []
    seen: set[str] = set()
    for index, step in enumerate(steps, start=1):
        name = str(step["name"])
        layer = str(step.get("layer") or "audit")
        state = str(step.get("state") or "idle")
        if layer not in ALLOWED_LAYERS:
            raise ValueError(f"unknown flow layer: {layer!r}")
        if state not in ALLOWED_STATES:
            raise ValueError(f"unknown flow state: {state!r}")
        node_id = f"n{index:02d}"
        if name in _EXTRACT_ROWS:
            x, y = 0.0, _EXTRACT_ROWS[name]
        else:
            x, y = 1.0, _CHAIN_ROWS.get(name, -1.0 - 0.1 * index)
        nodes.append(
            {
                "id": node_id,
                "layer": layer,
                "state": state,
                "x": f"{x:.1f}",
                "y": f"{y:.1f}",
                "label": name,
                "duration": _fmt_duration(step.get("duration_s")),
            }
        )
        if seen:
            edges.append({"src": f"n{index - 1:02d}", "dst": node_id})
        seen.add(node_id)
    return {"nodes": nodes, "edges": edges}
