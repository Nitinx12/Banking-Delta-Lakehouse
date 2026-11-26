"""Render index.html for the Streamlit host: inline assets, rewrite doc links, inject JSON."""

from __future__ import annotations

import base64
import json
import mimetypes
import re
from pathlib import Path
from typing import Any

REPO_URL = "https://github.com/Nitinx12/Banking-Delta-Lakehouse"
BRANCH = "main"

# Anything larger is not stuffed into the iframe; it is linked on GitHub instead.
MAX_INLINE_BYTES = 256_000

_ASSET_RE = re.compile(r'((?:src|href)=")(assets/[\w./-]+)(")')
_DOC_RE = re.compile(r'href="((?:[\w-]+\.md)|(?:docs|reports)/[\w./-]+)"')
_FACTS_RE = re.compile(
    r'(<script id="site-facts" type="application/json">)(.*?)(</script>)', re.S
)
_LIVE_RE = re.compile(
    r'(<script id="live-data" type="application/json">)(.*?)(</script>)', re.S
)
_FALLBACK_RE = re.compile(
    r'<script id="site-facts-fallback" type="application/json">(.*?)</script>', re.S
)


def load_html(root: Path) -> str:
    """Read the landing page from `root`."""
    return (root / "index.html").read_text(encoding="utf-8")


def asset_uri(rel: str, root: Path) -> str:
    """Data URI for a small local asset; a missing one keeps its path so checkers see it."""
    path = root / rel
    if not path.is_file():
        return rel
    if path.stat().st_size > MAX_INLINE_BYTES:
        return f"{REPO_URL}/raw/{BRANCH}/{rel}"
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    b64 = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{b64}"


def inline_assets(html: str, root: Path) -> str:
    """Turn local `assets/...` references into data URIs so they resolve in the iframe."""
    return _ASSET_RE.sub(
        lambda m: m.group(1) + asset_uri(m.group(2), root) + m.group(3), html
    )


def rewrite_doc_links(html: str, repo_url: str = REPO_URL, branch: str = BRANCH) -> str:
    """Send repo-relative document links to GitHub; they 404 inside the iframe."""
    return _DOC_RE.sub(
        lambda m: f'href="{repo_url}/blob/{branch}/{m.group(1)}"'
        ' target="_blank" rel="noreferrer"',
        html,
    )


def fallback_facts(html: str) -> dict[str, Any]:
    """Parse the static facts baked into index.html."""
    match = _FALLBACK_RE.search(html)
    if match is None:
        return {}
    return json.loads(match.group(1))


def inject_json(html: str, script_id: str, payload: Any) -> str:
    """Replace one JSON script block's body, leaving the tags in place."""
    pattern = _FACTS_RE if script_id == "site-facts" else _LIVE_RE
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    replaced, count = pattern.subn(
        lambda m: f"{m.group(1)}\n      {body}\n    {m.group(3)}", html
    )
    if count != 1:
        raise ValueError(f"expected exactly one #{script_id} block, found {count}")
    return replaced


def render(root: Path, live: dict[str, Any] | None = None) -> str:
    """Build the HTML the Streamlit iframe shows, with facts and live data injected."""
    html = inline_assets(load_html(root), root)
    html = rewrite_doc_links(html)
    html = inject_json(html, "site-facts", fallback_facts(html))
    if live is not None:  # an empty dict is a real "no rows" answer, not "off"
        html = inject_json(html, "live-data", live)
    return html
