"""Run keys, output paths and retention pruning for the report builder."""

from __future__ import annotations

import os
import re
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPORTS_DIR = Path(__file__).resolve().parents[1]
PROJECT_ROOT = REPORTS_DIR.parent
DATA_DIR = REPORTS_DIR / "data"
FIXTURES_DIR = DATA_DIR / "fixtures"
CONTEXT_SCHEMA = DATA_DIR / "context.schema.json"
PDF_NAMES: dict[str, str] = {
    "daily": "report.pdf",
    "incident": "incident.pdf",
    "weekly": "weekly.pdf",
}
_UNSAFE = re.compile(r"[^A-Za-z0-9_]+")


def run_key(dag_run_id: str | None) -> str:
    """Reduce a dag run id to a filesystem safe run key."""
    key = _UNSAFE.sub("_", dag_run_id or "").strip("_")
    return key or "manual"


def output_root() -> Path:
    """Report output root; REPORT_OUTPUT_DIR wins, default reports/output."""
    configured = os.environ.get("REPORT_OUTPUT_DIR", "").strip()
    root = Path(configured) if configured else REPORTS_DIR / "output"
    return root if root.is_absolute() else PROJECT_ROOT / root


def run_dir(key: str) -> Path:
    """Folder holding every artefact of one run."""
    return output_root() / "runs" / key


def pdf_path(key: str, kind: str) -> Path:
    """Path of the PDF for one run and kind (report.pdf for daily)."""
    return run_dir(key) / PDF_NAMES[kind]


def latest_pdf(kind: str) -> Path:
    """Stable latest copy the mail task picks up."""
    return output_root() / PDF_NAMES[kind]


def context_path() -> Path:
    """Where the collector writes the versioned context document."""
    return DATA_DIR / "context.json"


def fixture_paths() -> list[Path]:
    """Every tracked fixture context, sorted for deterministic runs."""
    return sorted(FIXTURES_DIR.glob("*.json"))


def retention_days() -> int:
    """Run folders older than this many days are pruned."""
    return int(os.environ.get("REPORT_RETENTION_DAYS", "30"))


def prune_runs(days: int | None = None, *, now: datetime | None = None) -> list[Path]:
    """Delete run folders outside the retention window; return what went."""
    limit = retention_days() if days is None else days
    reference = now or datetime.now(timezone.utc)
    cutoff = reference - timedelta(days=limit)
    removed: list[Path] = []
    root = output_root() / "runs"
    if not root.is_dir():
        return removed
    for entry in sorted(root.iterdir()):
        if not entry.is_dir():
            continue
        mtime = datetime.fromtimestamp(entry.stat().st_mtime, tz=timezone.utc)
        if mtime < cutoff:
            shutil.rmtree(entry)
            removed.append(entry)
    return removed
