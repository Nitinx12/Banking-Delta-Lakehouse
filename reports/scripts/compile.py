"""latexmk wrapper; compile failures exit 0 at the CLI and never raise."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from .paths import REPORTS_DIR

LATEXMK_TIMEOUT_S = 600
DEFAULT_EPOCH = "1760000000"
_PAGES = re.compile(r"Output written on .*?\((\d+) pages?", re.IGNORECASE)


def latexmk_available() -> bool:
    """The compile step needs latexmk on PATH."""
    return shutil.which("latexmk") is not None


def page_count(log_path: Path | None) -> int | None:
    """Number of pages of the compiled PDF, read from the compile log."""
    if log_path is None or not log_path.is_file():
        return None
    match = _PAGES.search(log_path.read_text(encoding="utf-8", errors="replace"))
    return int(match.group(1)) if match else None


def source_date_epoch(ended_at: str | None) -> str:
    """Epoch that keeps the build reproducible: the run end time when known."""
    if ended_at:
        try:
            stamp = datetime.fromisoformat(ended_at)
        except ValueError:
            stamp = None
        if stamp is not None:
            if stamp.tzinfo is None:
                stamp = stamp.replace(tzinfo=timezone.utc)
            return str(int(stamp.timestamp()))
    return os.environ.get("SOURCE_DATE_EPOCH", DEFAULT_EPOCH)


def _redact_log(text: str) -> str:
    """Secrets never reach the log file kept next to the report."""
    try:
        from src.utils.audit import _redact
    except ImportError:
        return text
    return _redact(text)


def compile_pdf(
    workdir: Path,
    *,
    jobname: str = "report",
    log_path: Path | None = None,
    timeout: int = LATEXMK_TIMEOUT_S,
    epoch: str | None = None,
) -> bool:
    """Run latexmk in workdir; False on any failure, log kept for the run folder."""
    env = dict(os.environ)
    env["SOURCE_DATE_EPOCH"] = epoch or os.environ.get(
        "SOURCE_DATE_EPOCH", DEFAULT_EPOCH
    )
    env["FORCE_SOURCE_DATE"] = "1"
    command = [
        "latexmk",
        "-r",
        str(REPORTS_DIR / "latexmkrc"),
        f"-jobname={jobname}",
        "main.tex",
    ]
    try:
        result = subprocess.run(
            command,
            cwd=workdir,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(
            _redact_log(result.stdout + "\n" + result.stderr), encoding="utf-8"
        )
    return result.returncode == 0
