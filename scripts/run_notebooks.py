# Usage: python scripts/run_notebooks.py [--notebooks mysql mongodb databricks] [--output-dir DIR] [--timeout 300] [--keep-going]
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from utils.logger import get_logger

PROJECT_ROOT = Path(__file__).resolve().parents[1]
NOTEBOOK_DIR = PROJECT_ROOT / "notebooks"

logger = get_logger("run_notebooks")


DEFAULT_NOTEBOOKS: tuple[str, ...] = ("mysql", "mongodb", "databricks")
NOTEBOOK_TIMEOUT_SECONDS = int(os.environ.get("NOTEBOOK_TIMEOUT_SECONDS", "300"))


def _kill_tree(proc: subprocess.Popen) -> None:
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
            capture_output=True,
            check=False,
        )
    else:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
    proc.wait()


def run_notebook(name: str, output_dir: Path | None, timeout: int) -> int:
    nb_path = NOTEBOOK_DIR / f"{name}.ipynb"
    if not nb_path.is_file():
        logger.error("notebook not found: %s", nb_path)
        return 2

    cmd = [
        sys.executable,
        "-m",
        "jupyter",
        "nbconvert",
        "--execute",
        "--to",
        "notebook",
    ]
    if output_dir is None:
        cmd.append("--inplace")
    else:
        cmd += ["--output", name, "--output-dir", str(output_dir)]
    cmd.append(str(nb_path))

    logger.info("=== %s ===", name)
    started = time.monotonic()
    env = dict(os.environ)
    env["PYTHONWARNINGS"] = "ignore::RuntimeWarning"
    proc = subprocess.Popen(
        cmd,
        cwd=PROJECT_ROOT,
        start_new_session=(os.name != "nt"),
        env=env,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    _stderr_noise = (
        "Proactor event loop does not implement add_reader",
        "Kernel is running over TCP without encryption",
        "CurveZMQ",
        "Use IPC transport or launch with",
    )

    def _drain_stderr() -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            if any(marker in line for marker in _stderr_noise):
                continue
            sys.stderr.write(line)
            sys.stderr.flush()

    drain = threading.Thread(target=_drain_stderr, daemon=True)
    drain.start()
    try:
        code = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_tree(proc)
        code = 124
        logger.error("%s exceeded %ds; process tree killed", name, timeout)
    except KeyboardInterrupt:
        _kill_tree(proc)
        raise
    finally:
        drain.join(timeout=5)
        if proc.stderr is not None:
            proc.stderr.close()
    elapsed = time.monotonic() - started
    if code == 0:
        logger.info("%s finished in %.0fs (exit 0)", name, elapsed)
    else:
        logger.warning("%s failed in %.0fs (exit %s)", name, elapsed, code)
    return code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Execute the project notebooks.")
    parser.add_argument(
        "--notebooks",
        nargs="+",
        default=list(DEFAULT_NOTEBOOKS),
        help="notebook stems to run (default: mysql mongodb databricks)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="write executed copies here instead of editing in place",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=NOTEBOOK_TIMEOUT_SECONDS,
        help="per-notebook timeout in seconds",
    )
    parser.add_argument(
        "--keep-going",
        action="store_true",
        help="continue after a notebook fails",
    )
    args = parser.parse_args(argv)

    if args.output_dir is not None:
        args.output_dir.mkdir(parents=True, exist_ok=True)

    results: dict[str, str] = {}
    for name in args.notebooks:
        try:
            code = run_notebook(name, args.output_dir, args.timeout)
        except KeyboardInterrupt:
            results[name] = "INTERRUPTED"
            break
        results[name] = "SUCCESS" if code == 0 else f"FAILED (exit {code})"
        if code != 0 and not args.keep_going:
            logger.error("%s failed; stopping (use --keep-going to continue)", name)
            break

    for name in args.notebooks:
        results.setdefault(name, "NOT RUN")

    logger.info("Results: %s", results)
    return 0 if all(results[n] == "SUCCESS" for n in args.notebooks) else 1


if __name__ == "__main__":
    sys.exit(main())
