"""scripts/apply_sql_smoke.py - apply the bootstrap SQL to a DISPOSABLE Postgres.

Portable replacement for the shell loop behind `make sql-smoke`: the same files,
in the same order, with the same exclusions and the same `psql -v ON_ERROR_STOP=1`
invocation, so the target behaves identically under Windows cmd.exe and bash.
Refuses to run unless ALLOW_SQL_SMOKE=1 - never point it at the real warehouse.

    uv run python scripts/apply_sql_smoke.py
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from rich.console import Console

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from utils import config as _config  # noqa: F401  (loads .env for PG_HOST ...)

REPO_ROOT: Path = Path(__file__).resolve().parents[1]
console = Console()

REFUSAL = (
    "Refusing: set ALLOW_SQL_SMOKE=1 and point PG_* at a THROWAWAY database "
    "(never the real warehouse)."
)

# (directory, substrings that exclude a file from its repo-relative posix path)
_GROUPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("sql/scripts", ("00_create_database", "05_switch")),
    ("sql/functions", ()),
    ("sql/staging", ("/00_master", "/99_debug")),
    ("sql/analytics", ("/00_master", "/99_debug")),
    ("sql/marts", ("/00_master", "/99_debug")),
    ("tests/data-quality/raw", ("/00_master",)),
    ("tests/data-quality/staging", ("/00_master",)),
    ("tests/data-quality/analytics", ("/00_master",)),
    ("tests/data-quality/marts", ("/00_master",)),
)


def sql_files(root: Path) -> list[Path]:
    """The SQL files psql must apply, grouped and sorted like the make loop."""
    files: list[Path] = []
    for directory, exclusions in _GROUPS:
        folder = root / directory
        if not folder.is_dir():
            raise FileNotFoundError(f"missing SQL directory: {folder}")
        for path in sorted(folder.glob("*.sql")):
            relative = path.relative_to(root).as_posix()
            if not any(token in relative for token in exclusions):
                files.append(path)
    return files


def psql_command(path: Path) -> list[str]:
    """psql flags for one file: stop at the first error, no prompts, quiet."""
    return [
        "psql",
        "-v",
        "ON_ERROR_STOP=1",
        "-X",
        "-q",
        "-h",
        os.environ.get("PG_HOST", "localhost"),
        "-p",
        os.environ.get("PG_PORT", "5432"),
        "-d",
        os.environ.get("PG_DB", "banking_delta"),
        "-U",
        os.environ.get("PG_USER", "postgres"),
        "-f",
        str(path),
    ]


def psql_env() -> dict[str, str]:
    """Child environment carrying the project password for libpq."""
    env = os.environ.copy()
    if os.environ.get("PG_PASS") and not env.get("PGPASSWORD"):
        env["PGPASSWORD"] = os.environ["PG_PASS"]
    return env


def main(argv: list[str] | None = None) -> int:
    """Refuse without ALLOW_SQL_SMOKE=1, then apply every file; 0 = all applied."""
    parser = argparse.ArgumentParser(
        description="Apply bootstrap SQL and DQ suites to a DISPOSABLE Postgres."
    )
    parser.parse_args(argv)

    if os.environ.get("ALLOW_SQL_SMOKE") != "1":
        console.print(f"[red bold]{REFUSAL}[/red bold]")
        return 1

    try:
        files = sql_files(REPO_ROOT)
    except FileNotFoundError as exc:
        console.print(f"[red]{exc}[/red]")
        return 1

    for path in files:
        console.print(f"[dim]apply {path.relative_to(REPO_ROOT).as_posix()}[/dim]")
        try:
            result = subprocess.run(psql_command(path), env=psql_env(), check=False)
        except FileNotFoundError:
            console.print("[red bold]psql not found on PATH[/red bold]")
            return 1
        if result.returncode != 0:
            console.print(
                f"[red bold]psql failed on {path.name} (exit {result.returncode})"
                "[/red bold]"
            )
            return 1

    console.print("[green bold]sql-smoke OK[/green bold]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
