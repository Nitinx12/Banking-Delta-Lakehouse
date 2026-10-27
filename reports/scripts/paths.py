"""Run keys, output paths and retention pruning for the report builder."""

from __future__ import annotations

import os
import re
import shutil
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

REPORTS_DIR = Path(__file__).resolve().parents[1]
PROJECT_ROOT = REPORTS_DIR.parent
DATA_DIR = REPORTS_DIR / "data"
FIXTURES_DIR = DATA_DIR / "fixtures"
TEMPLATE_DIR = REPORTS_DIR / "template"
CHAPTERS_DIR = REPORTS_DIR / "chapters"
BUILD_DIR = REPORTS_DIR / "build"
FIGURES_DIR = REPORTS_DIR / "figures"
STYLE_FILE = TEMPLATE_DIR / "bankingreport.sty"
LATEXMKRC = REPORTS_DIR / "latexmkrc"
MAIN_TEX = REPORTS_DIR / "main.tex"
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


def run_dir(key: str, root: Path | None = None) -> Path:
    """Folder holding every artefact of one run."""
    return (root or output_root()) / "runs" / key


def pdf_path(key: str, kind: str, root: Path | None = None) -> Path:
    """Path of the PDF for one run and kind (report.pdf for daily)."""
    return run_dir(key, root) / PDF_NAMES[kind]


def latest_pdf(kind: str, root: Path | None = None) -> Path:
    """Stable latest copy the mail task picks up."""
    return (root or output_root()) / PDF_NAMES[kind]


def context_path() -> Path:
    """Where the collector writes the versioned context document."""
    return DATA_DIR / "context.json"


def fixture_paths() -> list[Path]:
    """Every tracked fixture context, sorted for deterministic runs."""
    return sorted(FIXTURES_DIR.glob("*.json"))


def fixture_path(name: str) -> Path:
    """Resolve a fixture by bare name, by path or by path relative to the repo."""
    candidate = Path(name)
    for option in (candidate, PROJECT_ROOT / candidate, FIXTURES_DIR / f"{name}.json"):
        if option.is_file():
            return option
    return FIXTURES_DIR / f"{name}.json"


def retention_days() -> int:
    """Run folders older than this many days are pruned."""
    return int(os.environ.get("REPORT_RETENTION_DAYS", "30"))


def load_report_config() -> dict[str, Any]:
    """The kind, chapter and threshold configuration."""
    import yaml

    with (REPORTS_DIR / "config" / "report.yaml").open(encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def load_slo_config() -> dict[str, Any]:
    """Freshness windows for tables without a contract window."""
    import yaml

    with (REPORTS_DIR / "config" / "slo.yaml").open(encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def prune_runs(
    days: int | None = None,
    *,
    now: datetime | None = None,
    root: Path | None = None,
) -> list[Path]:
    """Delete run folders outside the retention window; return what went."""
    limit = retention_days() if days is None else days
    reference = now or datetime.now(UTC)
    cutoff = reference - timedelta(days=limit)
    removed: list[Path] = []
    runs = (root or output_root()) / "runs"
    if not runs.is_dir():
        return removed
    for entry in sorted(runs.iterdir()):
        if not entry.is_dir():
            continue
        mtime = datetime.fromtimestamp(entry.stat().st_mtime, tz=UTC)
        if mtime < cutoff:
            shutil.rmtree(entry)
            removed.append(entry)
    return removed
