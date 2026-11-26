"""Landing page contract: index.html stays consistent and app.py serves it."""

from __future__ import annotations

import json
import re
import socket
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.smoke

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "site"))  # site/ has no __init__.py by design

# Captured at import, before the no_network fixture patches socket.connect.
_REAL_CONNECT = socket.socket.connect

import site_audit  # noqa: E402
import site_render  # noqa: E402

# Copy from the previous project that must never survive the rebrand.
_STALE = [
    ("Fleet dbt", re.compile(r"Fleet dbt")),
    ("old repository", re.compile(r"Fleet-dbt-warehouse")),
    ("dbt", re.compile(r"\bdbt\b")),
    ("bronze/silver", re.compile(r"\b(bronze|silver)\b")),
    ("Kafka", re.compile(r"\bKafka\b")),
    ("fleet sources", re.compile(r"fleet_registry|fleet_operations")),
]

_SKIP_HREF = re.compile(r"^(#|https?:|mailto:|data:|javascript:)")


def _html() -> str:
    return (ROOT / "index.html").read_text(encoding="utf-8")


def _scripts(html: str) -> list[dict[str, str]]:
    return [
        {
            "attrs": attrs,
            "id": _attr(attrs, "id"),
            "type": _attr(attrs, "type"),
            "body": body,
        }
        for attrs, body in re.findall(r"<script([^>]*)>([\s\S]*?)</script>", html)
    ]


def _attr(attrs: str, name: str) -> str:
    match = re.search(rf'\b{name}="([^"]+)"', attrs)
    return match.group(1) if match else ""


def test_index_json_blocks_are_valid() -> None:
    html = _html()
    blocks = {
        s["id"]: s["body"] for s in _scripts(html) if s["type"] == "application/json"
    }
    assert {"live-data", "site-facts", "site-facts-fallback"} <= blocks.keys()
    facts = json.loads(blocks["site-facts-fallback"])
    assert len(facts) >= 30, "the fallback facts block lost keys"
    # The other two are placeholders until app.py injects the real payload.
    assert re.fullmatch(r"\s*__SITE_FACTS__\s*", blocks["site-facts"])
    assert re.fullmatch(r"\s*__LIVE_DATA__\s*", blocks["live-data"])


def test_render_injects_facts_and_inlines_assets() -> None:
    rendered = site_render.render(ROOT)
    assert "__SITE_FACTS__" not in rendered
    assert "__LIVE_DATA__" in rendered, "offline render must keep the demo placeholder"
    assert "data:image/png;base64," in rendered, "insight charts were not inlined"
    docs = re.search(r'href="([^"]*blob/main/[^"]+)"', rendered)
    assert docs, "document links were not rewritten to GitHub"
    assert json.loads(
        re.search(
            r'<script id="site-facts" type="application/json">(.*?)</script>',
            rendered,
            re.S,
        ).group(1)
    )


def test_every_referenced_fact_is_defined() -> None:
    html = _html()
    facts = json.loads(
        re.search(
            r'<script id="site-facts-fallback" type="application/json">(.*?)</script>',
            html,
            re.S,
        ).group(1)
    )
    main = next(s for s in _scripts(html) if s["type"] != "application/json")
    read = set(re.findall(r'data-fact="([^"]+)"', html))
    read |= set(re.findall(r"(?:FACTS|num)\(\s*['\"]([^'\"]+)['\"]\s*\)", main["body"]))
    read |= set(re.findall(r"FACTS\[\s*['\"]([^'\"]+)['\"]\s*\]", main["body"]))
    missing = sorted(key for key in read if key not in facts)
    assert not missing, f"facts referenced but not defined: {missing}"


def test_index_links_anchors_and_make_targets_resolve() -> None:
    html = _html()
    ids = set(re.findall(r'\bid="([^"]+)"', html))
    anchors = {a for a in re.findall(r'\bhref="#([^"]+)"', html)}
    assert not anchors - ids, f"anchors with no target: {sorted(anchors - ids)}"

    targets = {
        href.split("#")[0]
        for href in re.findall(r'\b(?:href|src)="([^"]+)"', html)
        if not _SKIP_HREF.match(href)
    }
    dead = sorted(t for t in targets if t and not (ROOT / t).exists())
    assert not dead, f"dead local links: {dead}"

    known = set(
        re.findall(r"^([A-Za-z0-9_-]+):", (ROOT / "Makefile").read_text(), re.M)
    )
    used = set(re.findall(r"\bmake ([A-Za-z0-9_-]+)", html))
    assert not used - known, f"make targets not in Makefile: {sorted(used - known)}"


def test_index_has_no_stale_copy() -> None:
    html = _html()
    hits = [label for label, pattern in _STALE if pattern.search(html)]
    assert not hits, f"stale copy still present: {hits}"


def test_audit_allowlist_is_read_only() -> None:
    assert list(site_audit.QUERIES) == [
        "Pipeline runs",
        "Table runs",
        "Data quality",
        "DQ latest",
    ]
    for name, sql in site_audit.QUERIES.items():
        assert sql.startswith("select * from audit."), name
        assert not re.search(
            r"\b(insert|update|delete|drop|truncate|alter)\b", sql, re.I
        ), name


def test_app_serves_the_landing_page(monkeypatch: pytest.MonkeyPatch) -> None:
    # AppTest's script runner opens a loopback self-pipe; it never reaches a server.
    monkeypatch.setattr(socket.socket, "connect", _REAL_CONNECT)
    from streamlit.testing.v1 import AppTest

    app = AppTest.from_file(str(ROOT / "app.py")).run(timeout=30)
    assert not app.exception, app.exception
    assert [t.label for t in app.tabs] == ["Pipeline site", "Live audit status"]
    srcdoc = app.get("iframe")[0].proto.srcdoc
    assert "Banking Delta Lakehouse" in srcdoc
    assert "__SITE_FACTS__" not in srcdoc
    facts = re.search(
        r'<script id="site-facts" type="application/json">(.*?)</script>', srcdoc, re.S
    )
    assert facts, "injected site-facts block is not closed"
    assert json.loads(facts.group(1))
    assert not any(pattern.search(srcdoc) for _, pattern in _STALE)
