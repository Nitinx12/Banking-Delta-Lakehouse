"""latexmk wrapper; compile failures exit 0 at the CLI and never raise."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path

from .paths import REPORTS_DIR

LATEXMK_TIMEOUT_S = 600
DEFAULT_EPOCH = "1760000000"
_PAGES = re.compile(r"Output written on .*?\((\d+) pages?", re.IGNORECASE)
_UNLINK_ATTEMPTS = 5
_UNLINK_DELAY_S = 0.2


def latexmk_available() -> bool:
    """The compile step needs latexmk on PATH."""
    return shutil.which("latexmk") is not None


def page_count(log_path: Path | None) -> int | None:
    """Number of pages of the compiled PDF, read from the last pass of the log."""
    if log_path is None or not log_path.is_file():
        return None
    matches = _PAGES.findall(log_path.read_text(encoding="utf-8", errors="replace"))
    return int(matches[-1]) if matches else None


def latexmk_dirs(workdir: Path) -> tuple[Path, Path]:
    """Output and aux directory of the shipped latexmkrc, relative to workdir."""
    out_dir = "build"
    aux_dir = "build/aux"
    rc = REPORTS_DIR / "latexmkrc"
    if rc.is_file():
        for line in rc.read_text(encoding="utf-8").splitlines():
            match = re.match(r"\s*\$(out|aux)_dir\s*=\s*['\"]([^'\"]+)['\"]", line)
            if match:
                if match.group(1) == "out":
                    out_dir = match.group(2)
                else:
                    aux_dir = match.group(2)
    return workdir / out_dir, workdir / aux_dir


def clean_job_state(out_dir: Path, aux_dir: Path, jobname: str) -> list[Path]:
    """Drop the LaTeX state of one job so a stale or broken aux cannot leak in.

    Windows keeps the handle of a file for a moment after the run that wrote
    it ended, so a locked file is retried and then left in place.
    """
    targets = [
        aux_dir / f"{jobname}{suffix}"
        for suffix in (".aux", ".fdb_latexmk", ".fls", ".pdf")
    ]
    targets.append(out_dir / f"{jobname}.pdf")
    return [path for path in targets if not _remove(path)]


def _remove(path: Path) -> bool:
    """Delete one file; False when it is still locked by another process."""
    for _ in range(_UNLINK_ATTEMPTS):
        try:
            path.unlink(missing_ok=True)
            return True
        except PermissionError:
            time.sleep(_UNLINK_DELAY_S)
        except OSError:
            return False
    return False


def source_date_epoch(ended_at: str | None) -> str:
    """Epoch that keeps the build reproducible: the run end time when known."""
    if ended_at:
        try:
            stamp = datetime.fromisoformat(ended_at)
        except ValueError:
            stamp = None
        if stamp is not None:
            if stamp.tzinfo is None:
                stamp = stamp.replace(tzinfo=UTC)
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
    out_dir, aux_dir = latexmk_dirs(workdir)
    clean_job_state(out_dir, aux_dir, jobname)
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
