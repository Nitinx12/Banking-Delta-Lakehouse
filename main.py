"""Run the full daily pipeline in gate order with a rich run report.

Order: raw extract -> raw DQ -> staging load -> staging DQ -> analytics load
-> analytics DQ -> marts load -> marts DQ -> publish to Databricks. A failing
step stops the run, so nothing downstream sees half-loaded data, unless
--keep-going is passed.

    python main.py                       # whole pipeline
    python main.py --list                # show the steps in order
    python main.py --from staging-load   # start at a step
    python main.py --only marts-load --only marts-tests
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

PROJECT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

from utils.audit import start_pipeline_run  # noqa: E402
from utils.connection import get_pg_connection  # noqa: E402

SCRIPTS_DIR = PROJECT_ROOT / "scripts"
SQL_DIR = PROJECT_ROOT / "sql"

# Legacy Windows consoles default to cp1252 and choke on "·" / "—" glyphs.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):  # noqa: PERF203 - non-seekable / detached stream
        pass

console = Console(legacy_windows=False)

SUCCESS = "SUCCESS"
FAILED = "FAILED"
SKIPPED = "SKIPPED"


@dataclass(frozen=True)
class Step:
    """One gated stage: either a child script or a PostgreSQL master load."""

    name: str
    layer: str
    title: str
    script: Path | None = None
    schema: str | None = None


@dataclass
class StepResult:
    """Outcome of one pipeline step."""

    step: Step
    status: str = SKIPPED
    seconds: float = 0.0
    detail: str = ""


def build_steps() -> tuple[Step, ...]:
    """Return every pipeline step in execution order."""
    return (
        Step(
            "raw-inject",
            "raw",
            "Land MySQL, MongoDB and Databricks into the raw schema",
            script=SCRIPTS_DIR / "run_jobs.py",
        ),
        Step(
            "raw-tests",
            "raw",
            "Data-quality gate on the raw schema",
            script=SCRIPTS_DIR / "run_raw_tests.py",
        ),
        Step(
            "staging-load",
            "staging",
            "Build the staging schema from raw",
            schema="staging",
        ),
        Step(
            "staging-tests",
            "staging",
            "Data-quality gate on the staging schema",
            script=SCRIPTS_DIR / "run_staging_tests.py",
        ),
        Step(
            "analytics-load",
            "analytics",
            "Build dims and facts from staging",
            schema="analytics",
        ),
        Step(
            "analytics-tests",
            "analytics",
            "Data-quality gate on the analytics schema",
            script=SCRIPTS_DIR / "run_analytics_tests.py",
        ),
        Step("marts-load", "marts", "Build the marts tables", schema="marts"),
        Step(
            "marts-tests",
            "marts",
            "Data-quality gate on the marts schema",
            script=SCRIPTS_DIR / "run_marts_tests.py",
        ),
        Step(
            "publish",
            "marts",
            "Publish marts to Databricks Delta",
            script=PROJECT_ROOT / "src" / "jobs" / "publish_marts.py",
        ),
    )


def select_steps(
    steps: tuple[Step, ...], start_at: str | None, only: list[str]
) -> list[Step]:
    """Filter the pipeline by --from/--only, rejecting unknown step names."""
    names = [step.name for step in steps]
    if only:
        unknown = sorted(set(only) - set(names))
        if unknown:
            raise ValueError(f"unknown step(s): {', '.join(unknown)}")
        return [step for step in steps if step.name in only]
    if start_at:
        if start_at not in names:
            raise ValueError(f"unknown step: {start_at}")
        return list(steps[names.index(start_at) :])
    return list(steps)


def run_script(script: Path) -> tuple[str, str]:
    """Run one child script to completion; return (status, detail)."""
    code = subprocess.run(
        [sys.executable, str(script)], cwd=PROJECT_ROOT, check=False
    ).returncode
    if code == 0:
        return SUCCESS, ""
    return FAILED, f"exit {code}"


def _first_line(exc: BaseException) -> str:
    """Return the first line of an error, short enough for the summary table."""
    lines = str(exc).strip().splitlines() or [type(exc).__name__]
    return lines[0][:200]


def _attach_audit_run() -> uuid.UUID | None:
    """Pipeline run to log against; None outside Airflow (manual runs stay independent)."""
    dag_run_id = os.environ.get("AIRFLOW_CTX_DAG_RUN_ID")
    if not dag_run_id:
        return None
    return start_pipeline_run(
        dag_id=os.environ.get("AIRFLOW_CTX_DAG_ID"),
        dag_run_id=dag_run_id,
        trigger_type="airflow",
    )


def run_load(schema: str) -> tuple[str, str]:
    """Refresh the schema's master procedure and CALL its sp_load_all()."""
    sql = (SQL_DIR / schema / "00_master_load.sql").read_text(encoding="utf-8")
    try:
        conn = get_pg_connection(application_name=f"main_{schema}")
    except Exception as exc:  # noqa: BLE001 - a connection error is this step's failure
        return FAILED, _first_line(exc)

    notices: list[str] = []
    try:
        pipeline_run_id = _attach_audit_run()
        with conn.cursor() as cur:
            cur.execute(sql)
            if pipeline_run_id is None:
                cur.execute(f"CALL {schema}.sp_load_all()")
            else:
                cur.execute(
                    f"CALL {schema}.sp_load_all(p_pipeline_run_id => %s)",
                    (pipeline_run_id,),
                )
        conn.commit()
    except Exception as exc:  # noqa: BLE001 - a DB error is the step failure we report
        conn.rollback()
        return FAILED, _first_line(exc)
    finally:
        notices = [line.strip() for line in conn.notices if line.strip()]
        conn.close()

    for notice in notices:
        console.print(f"    [dim]{notice}[/dim]")
    return SUCCESS, ""


def run_step(step: Step) -> tuple[str, str]:
    """Run a single step, whichever kind it is."""
    if step.schema:
        return run_load(step.schema)
    if step.script is None:
        return FAILED, "step is not runnable"
    return run_script(step.script)


def fmt_duration(seconds: float) -> str:
    """Render a duration as 45.2s, 12m 03s or 1h 02m 03s."""
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, secs = divmod(int(seconds), 60)
    if minutes < 60:
        return f"{minutes}m {secs:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m {secs:02d}s"


def status_text(status: str) -> Text:
    """Colour a step status for the summary table."""
    colours = {SUCCESS: "green", FAILED: "red", SKIPPED: "yellow"}
    return Text(status, style=f"bold {colours.get(status, 'white')}")


def print_steps(steps: list[Step]) -> None:
    """List the selected steps in execution order."""
    table = Table(
        title="Pipeline steps",
        show_header=True,
        header_style="bold cyan",
        box=None,
        pad_edge=False,
    )
    table.add_column("#", style="dim", justify="right")
    table.add_column("Layer", style="cyan")
    table.add_column("Step", style="white")
    table.add_column("Description")
    for index, step in enumerate(steps, start=1):
        table.add_row(str(index), step.layer, step.name, step.title)
    console.print(table)


def print_summary(results: list[StepResult], total_seconds: float) -> None:
    """Print the per-step report and the final pass/fail panel."""
    table = Table(
        title="Pipeline summary",
        show_header=True,
        header_style="bold cyan",
        box=None,
        pad_edge=False,
    )
    table.add_column("#", style="dim", justify="right")
    table.add_column("Layer", style="cyan")
    table.add_column("Step", style="white")
    table.add_column("Status", justify="center")
    table.add_column("Time", justify="right", style="dim")
    table.add_column("Detail", overflow="fold")

    for index, result in enumerate(results, start=1):
        table.add_row(
            str(index),
            result.step.layer,
            result.step.name,
            status_text(result.status),
            "—" if result.status == SKIPPED else fmt_duration(result.seconds),
            result.detail,
        )
    console.print()
    console.print(table)

    failed = [r for r in results if r.status == FAILED]
    done = [r for r in results if r.status == SUCCESS]
    noun = "step" if len(results) == 1 else "steps"
    if failed:
        console.print(
            Panel(
                f"[red bold]{len(failed)} of {len(results)} {noun} failed "
                f"({len(done)} succeeded) in {fmt_duration(total_seconds)}[/red bold]\n"
                f"[dim]first failure: {failed[0].step.name}[/dim]",
                border_style="red",
            )
        )
        return
    console.print(
        Panel(
            f"[green bold]All {len(results)} {noun} passed "
            f"in {fmt_duration(total_seconds)}[/green bold]",
            border_style="green",
        )
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run the daily pipeline in gate order: extract, DQ, loads, publish."
    )
    parser.add_argument(
        "--from",
        dest="start_at",
        metavar="STEP",
        help="start at this step instead of the first one",
    )
    parser.add_argument(
        "--only",
        action="append",
        metavar="STEP",
        help="run only these steps (repeatable, keeps pipeline order)",
    )
    parser.add_argument(
        "--keep-going",
        action="store_true",
        help="continue after a failing step instead of stopping",
    )
    parser.add_argument(
        "--list", action="store_true", help="list the steps in order and exit"
    )
    args = parser.parse_args(argv)

    try:
        steps = select_steps(build_steps(), args.start_at, args.only or [])
    except ValueError as exc:
        parser.error(str(exc))

    if args.list:
        print_steps(steps)
        return 0

    console.print(
        Panel.fit(
            f"[bold]Banking-Delta daily pipeline[/bold]\n"
            f"[dim]{len(steps)} step(s)  ·  stop on first failure: "
            f"{'no' if args.keep_going else 'yes'}[/dim]",
            border_style="cyan",
        )
    )

    results: list[StepResult] = []
    started = time.monotonic()
    try:
        for index, step in enumerate(steps, start=1):
            console.print()
            console.rule(
                f"[cyan]{index}/{len(steps)}[/cyan] {step.name} — {step.title}"
            )
            step_started = time.monotonic()
            try:
                status, detail = run_step(step)
            except KeyboardInterrupt:
                results.append(
                    StepResult(
                        step, FAILED, time.monotonic() - step_started, "interrupted"
                    )
                )
                raise
            results.append(
                StepResult(step, status, time.monotonic() - step_started, detail)
            )
            if status == FAILED and not args.keep_going:
                console.print(
                    f"[red bold]Stopping at {step.name}; "
                    f"later steps were not run (use --keep-going to override)[/red bold]"
                )
                break
    except KeyboardInterrupt:
        console.print("\n[yellow bold]Pipeline interrupted by user[/yellow bold]")

    executed = {result.step.name for result in results}
    for step in steps:
        if step.name not in executed:
            results.append(StepResult(step, SKIPPED))

    print_summary(results, time.monotonic() - started)
    return 1 if any(r.status == FAILED for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
