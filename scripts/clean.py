"""scripts/clean.py - remove caches and coverage output (`make clean`).

One implementation behind `make clean` and `tasks.bat clean`, so both runners
delete exactly the same things. `--reports` switches to the generated report
artefacts instead.

    uv run python scripts/clean.py
    uv run python scripts/clean.py --reports
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from collections.abc import Iterable
from pathlib import Path

from rich.console import Console

REPO_ROOT: Path = Path(__file__).resolve().parents[1]
console = Console()

_CACHE_ENTRIES = (
    ".pytest_cache",
    ".ruff_cache",
    ".mypy_cache",
    "htmlcov",
    ".coverage",
    "coverage.xml",
)
_REPORT_ENTRIES = ("reports/build", "reports/output")
# Walk the repo for __pycache__ but never enter these trees.
_PRUNED_DIRS = frozenset({".venv", ".git", ".spark", "node_modules"})


def cache_paths(root: Path) -> list[Path]:
    """Cache entries plus every __pycache__ outside the pruned directories."""
    paths = [root / name for name in _CACHE_ENTRIES]
    for dirpath, dirnames, _ in os.walk(root):
        dirnames[:] = [name for name in dirnames if name not in _PRUNED_DIRS]
        here = Path(dirpath)
        if here.name == "__pycache__":
            paths.append(here)
            dirnames[:] = []
    return paths


def report_paths(root: Path) -> list[Path]:
    """Generated report directories and the compiled figure PDFs."""
    paths = [root / name for name in _REPORT_ENTRIES]
    paths += sorted((root / "reports" / "figures").glob("*.pdf"))
    return paths


def remove(paths: Iterable[Path]) -> int:
    """Delete whatever exists; return how many entries went away."""
    removed = 0
    for path in paths:
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
        else:
            continue
        removed += 1
        console.print(f"[dim]removed {path.name}[/dim]")
    return removed


def main(argv: list[str] | None = None) -> int:
    """Delete caches (default) or report artefacts (--reports)."""
    parser = argparse.ArgumentParser(
        description="Remove caches and coverage output, or report artefacts."
    )
    parser.add_argument(
        "--reports",
        action="store_true",
        help="delete reports/build, reports/output and reports/figures/*.pdf",
    )
    args = parser.parse_args(argv)
    paths = report_paths(REPO_ROOT) if args.reports else cache_paths(REPO_ROOT)
    removed = remove(paths)
    if removed:
        console.print(f"[green]{removed} path(s) removed[/green]")
    else:
        console.print("[dim]nothing to remove[/dim]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
