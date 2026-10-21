"""TikZ flow layout is built from steps and rejects unknown layers or states."""

from __future__ import annotations

import json

import pytest

from reports.scripts import flow
from reports.scripts.paths import FIXTURES_DIR

pytestmark = pytest.mark.unit


def _steps(fixture: str) -> list[dict]:
    context = json.loads((FIXTURES_DIR / f"{fixture}.json").read_text(encoding="utf-8"))
    return context["steps"]


def test_flow_builds_one_node_per_step() -> None:
    steps = _steps("healthy")
    data = flow.build_flow(steps)
    assert [n["label"] for n in data["nodes"]] == [s["name"] for s in steps]
    assert len(data["edges"]) == len(steps) - 1
    assert all(n["id"].startswith("n") for n in data["nodes"])
    extracts = {n["label"]: n["x"] for n in data["nodes"] if n["x"] != "1.0"}
    assert set(extracts) == {"extract_mongo", "extract_databricks", "extract_mysql"}


def test_flow_formats_node_durations() -> None:
    data = flow.build_flow(_steps("healthy"))
    preflight = next(n for n in data["nodes"] if n["label"] == "preflight")
    assert preflight["duration"] == "22s"


def test_flow_rejects_unknown_layer() -> None:
    steps = [dict(_steps("healthy")[0], layer="martian")]
    with pytest.raises(ValueError, match="unknown flow layer"):
        flow.build_flow(steps)


def test_flow_rejects_unknown_state() -> None:
    steps = [dict(_steps("healthy")[0], state="sparkling")]
    with pytest.raises(ValueError, match="unknown flow state"):
        flow.build_flow(steps)
