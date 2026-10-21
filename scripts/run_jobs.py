"""scripts/run_jobs.py — run the raw-landing extract jobs in order.

One subprocess per source (each job owns its Spark session and audit pipeline
run), run sequentially so only one Spark/Java instance is alive at a time.
Each job gets EXTRACT_TIMEOUT_SECONDS (default 180); a job that exceeds it is
killed together with its JVM children and retried once, because a local Spark
executor that misses registration hangs forever instead of erroring.
Stops at the first failing job unless --keep-going is passed. Options this script
does not know (for example --tables or --parallel) are passed on to every job.

    python scripts/run_jobs.py                 # mongo -> databricks -> mysql
    python scripts/run_jobs.py --sources mongo
    python scripts/run_jobs.py --keep-going
    python scripts/run_jobs.py --sources mysql --tables accounts --parallel 2
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from utils.logger import get_logger

PROJECT_ROOT = Path(__file__).resolve().parents[1]

logger = get_logger("run_jobs")

# Canonical run order, one source each. Edit here to change the sequence.
JOBS: tuple[str, ...] = ("mongo", "databricks", "mysql")

EXTRACT_TIMEOUT_SECONDS = int(os.environ.get("EXTRACT_TIMEOUT_SECONDS", "180"))
MAX_ATTEMPTS = 2


def _kill_tree(proc: subprocess.Popen) -> None:
    """Kill the extract process and its JVM child so no orphan Spark survives."""
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
            capture_output=True,
            check=False,
        )
    else:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    proc.wait()


def run_job(source: str, extra: list[str]) -> int:
    """Run one extract job; kill and retry once if it hangs or fails; return its exit code."""
    script = PROJECT_ROOT / "src" / "jobs" / f"extract_{source}.py"
    cmd = [sys.executable, str(script), *extra]

    code = 1
    for attempt in range(1, MAX_ATTEMPTS + 1):
        logger.info(
            "=== %s (%s) | attempt %d/%d ===",
            source,
            script.name,
            attempt,
            MAX_ATTEMPTS,
        )
        started = time.monotonic()
        proc = subprocess.Popen(
            cmd, cwd=PROJECT_ROOT, start_new_session=(os.name != "nt")
        )
        try:
            code = proc.wait(timeout=EXTRACT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            _kill_tree(proc)
            code = 124
            logger.error(
                "%s exceeded %ds; process tree killed",
                source,
                EXTRACT_TIMEOUT_SECONDS,
            )
        except KeyboardInterrupt:
            _kill_tree(proc)
            raise
        elapsed = time.monotonic() - started
        if code == 0:
            logger.info("%s finished in %.0fs (exit 0)", source, elapsed)
            return 0
        logger.warning(
            "%s failed in %.0fs (exit %s)%s",
            source,
            elapsed,
            code,
            "; retrying once" if attempt < MAX_ATTEMPTS else "",
        )
    return code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run the raw-landing extract jobs in order."
    )
    parser.add_argument(
        "--sources",
        nargs="+",
        choices=JOBS,
        default=list(JOBS),
        help="subset to run, always executed in canonical order",
    )
    parser.add_argument(
        "--keep-going",
        action="store_true",
        help="continue after a job fails (default: stop at the first failure)",
    )
    args, extra = parser.parse_known_args(argv)

    wanted = set(args.sources)
    ordered = [source for source in JOBS if source in wanted]

    results: dict[str, str] = {}
    for source in ordered:
        try:
            code = run_job(source, extra)
        except KeyboardInterrupt:
            results[source] = "INTERRUPTED"
            break
        results[source] = "SUCCESS" if code == 0 else f"FAILED (exit {code})"
        if code != 0 and not args.keep_going:
            logger.error("%s failed; stopping (use --keep-going to continue)", source)
            break

    for source in ordered:
        results.setdefault(source, "NOT RUN")

    logger.info("Results: %s", results)
    return 0 if all(results[source] == "SUCCESS" for source in ordered) else 1


if __name__ == "__main__":
    sys.exit(main())
