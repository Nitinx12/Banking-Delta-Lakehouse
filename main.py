"""Run the full daily pipeline in gate order with a rich run report.

Order: raw extract -> raw DQ -> staging load -> staging DQ -> analytics load
-> analytics DQ -> marts load -> marts DQ -> publish to Databricks. A failing
step stops the run, so nothing downstream sees half-loaded data, unless
--keep-going is passed.

    python main.py                       # whole pipeline
    python main.py --list                # show the steps in order
    python main.py --from staging-load   # start at a step
    python main.py --only marts-load --only marts-tests
    python main.py --dag-id ... --dag-run-id ...  # Airflow integration
"""

from __future__ import annotations

import argparse
import contextlib
import functools
import os
import re
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from rich.console import Console
from rich.markup import escape
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

MASTER_LOAD_FILE = "00_master_load.sql"
_MANUAL_RUN_RE = re.compile(r"^[ \t]*-- Manual run", re.MULTILINE)
_PROCEDURE_RE = re.compile(r"CREATE\s+OR\s+REPLACE\s+PROCEDURE", re.IGNORECASE)


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
    valid = ", ".join(names)
    if only and start_at:
        raise ValueError("--from and --only cannot be combined")
    if only:
        unknown = sorted(set(only) - set(names))
        if unknown:
            raise ValueError(f"unknown step(s): {', '.join(unknown)} (valid: {valid})")
        return [step for step in steps if step.name in only]
    if start_at:
        if start_at not in names:
            raise ValueError(f"unknown step: {start_at} (valid: {valid})")
        return list(steps[names.index(start_at) :])
    return list(steps)


def run_script(
    script: Path, dag_id: str | None = None, dag_run_id: str | None = None
) -> tuple[str, str]:
    """Run one child script to completion; return (status, detail)."""
    if not script.is_file():
        return FAILED, f"script not found: {script}"
    cmd = [sys.executable, str(script)]
    if dag_id and dag_run_id:
        cmd.extend(["--dag-id", dag_id, "--dag-run-id", dag_run_id])
    # Children print the same glyphs; stop them crashing on cp1252 consoles.
    env = {**os.environ, "PYTHONIOENCODING": "utf-8:replace"}
    code = subprocess.run(cmd, cwd=PROJECT_ROOT, env=env, check=False).returncode
    if code == 0:
        return SUCCESS, ""
    return FAILED, f"exit {code}"


def _first_line(exc: BaseException) -> str:
    """Return the first line of an error, short enough for the summary table."""
    lines = str(exc).strip().splitlines() or [type(exc).__name__]
    return lines[0][:200]


@functools.cache
def _attach_audit_run(
    dag_id: str | None = None, dag_run_id: str | None = None
) -> uuid.UUID | None:
    """Pipeline run to log against; None outside Airflow (manual runs stay independent).

    Cached so every load step in one invocation logs against the SAME run
    instead of opening a new audit run per schema.
    """
    dag_run_id = dag_run_id or os.environ.get("AIRFLOW_CTX_DAG_RUN_ID")
    if not dag_run_id:
        return None
    return start_pipeline_run(
        dag_id=dag_id or os.environ.get("AIRFLOW_CTX_DAG_ID"),
        dag_run_id=dag_run_id,
        trigger_type="airflow",
    )


def _psql_env() -> dict[str, str]:
    """Environment for psql subprocesses (inherits os.environ + PGPASSWORD)."""
    env = os.environ.copy()
    pg_pass = os.environ.get("PG_PASS")
    if pg_pass:
        env["PGPASSWORD"] = pg_pass
    return env


def _run_psql_file(sql_file: Path, application_name: str) -> None:
    """Execute one SQL file with psql (ON_ERROR_STOP so any error fails the step)."""
    cmd = [
        "psql",
        "-v",
        "ON_ERROR_STOP=1",
        "-h",
        os.environ.get("PG_HOST", "localhost"),
        "-p",
        os.environ.get("PG_PORT", "5432"),
        "-d",
        os.environ.get("PG_DB", "banking_delta"),
        "-U",
        os.environ.get("PG_USER", "postgres"),
        "--set",
        f"application_name={application_name}",
        "-f",
        str(sql_file),
    ]
    try:
        subprocess.run(cmd, env=_psql_env(), check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"psql -f {sql_file} failed (exit {exc.returncode}):\n"
            f"STDOUT: {exc.stdout}\nSTDERR: {exc.stderr}"
        ) from exc


def _deploy_load_procedures(schema: str) -> None:
    """Create/replace every sp_load_* procedure in <schema> before sp_load_all runs.

    Each 0N_<name>.sql file defines its table, triggers, Unknown member and
    procedure, then ends with a manual-run CALL that must NOT fire here (the
    orchestrator calls sp_load_all once at the end). Strip that trailing block
    so deployment stays idempotent and does not double-load data.

    Files are deployed with psql -f (the way they are written to be run),
    because psycopg2's cur.execute() cannot reliably digest PL/pgSQL
    $$-quoted bodies in multi-statement batches.
    """
    sql_dir = SQL_DIR / schema
    if not sql_dir.is_dir():
        raise FileNotFoundError(f"missing SQL directory: {sql_dir}")
    app = f"main_{schema}_deploy"
    for path in sorted(sql_dir.glob("*.sql")):
        if path.name == MASTER_LOAD_FILE:
            continue
        source = path.read_text(encoding="utf-8")
        if not _PROCEDURE_RE.search(source):
            continue
        # Strip the trailing manual-run CALL block so we do not double-load data.
        matches = list(_MANUAL_RUN_RE.finditer(source))
        if matches:
            source = source[: matches[-1].start()].rstrip() + "\n"
        # Write the stripped source to a temp file so psql -f sees exactly what
        # we intend (no manual CALL at the end).
        import tempfile

        with tempfile.NamedTemporaryFile(
            "w", suffix=".sql", delete=False, encoding="utf-8"
        ) as tf:
            tf.write(source)
            tmp_path = Path(tf.name)
        try:
            _run_psql_file(tmp_path, app)
        finally:
            tmp_path.unlink(missing_ok=True)


def run_load(
    schema: str, dag_id: str | None = None, dag_run_id: str | None = None
) -> tuple[str, str]:
    """Deploy the schema's load procedures, then CALL its sp_load_all()."""
    master_file = SQL_DIR / schema / MASTER_LOAD_FILE
    try:
        conn = get_pg_connection(application_name=f"main_{schema}")
    except Exception as exc:  # noqa: BLE001 - a connection error is this step's failure
        return FAILED, _first_line(exc)

    try:
        pipeline_run_id = _attach_audit_run(dag_id, dag_run_id)
        # Deploy every sp_load_* procedure (including the master) with psql -f,
        # because psycopg2 cannot reliably digest PL/pgSQL $$-quoted bodies.
        app = f"main_{schema}_deploy"
        _run_psql_file(master_file, app)
        _deploy_load_procedures(schema)
        with conn.cursor() as cur:
            if pipeline_run_id is None:
                cur.execute(f"CALL {schema}.sp_load_all()")
            else:
                cur.execute(
                    f"CALL {schema}.sp_load_all(p_pipeline_run_id => %s)",
                    (pipeline_run_id,),
                )
        conn.commit()
    except Exception as exc:  # noqa: BLE001 - a DB error is the step failure we report
        with contextlib.suppress(Exception):  # connection may already be dead
            conn.rollback()
        return FAILED, _first_line(exc)
    finally:
        # Print notices on success AND failure; they usually explain the error.
        notices = [line.strip() for line in conn.notices if line.strip()]
        conn.close()
        for notice in notices:
            console.print(f"    [dim]{escape(notice)}[/dim]")
    return SUCCESS, ""


def run_step(
    step: Step, dag_id: str | None = None, dag_run_id: str | None = None
) -> tuple[str, str]:
    """Run a single step, whichever kind it is."""
    if step.schema:
        return run_load(step.schema, dag_id, dag_run_id)
    if step.script is None:
        return FAILED, "step is not runnable"
    return run_script(step.script, dag_id, dag_run_id)


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
            # Text(), not str: DB errors contain "[...]" which Rich would parse as markup.
            Text(result.detail),
        )
    console.print()
    console.print(table)

    failed = [r for r in results if r.status == FAILED]
    done = [r for r in results if r.status == SUCCESS]
    skipped = [r for r in results if r.status == SKIPPED]
    if failed or skipped:
        colour = "red" if failed else "yellow"
        lines = [
            f"[{colour} bold]{len(done)} passed, {len(failed)} failed, "
            f"{len(skipped)} not run in {fmt_duration(total_seconds)}[/{colour} bold]"
        ]
        if failed:
            lines.append(f"[dim]first failure: {escape(failed[0].step.name)}[/dim]")
        console.print(Panel("\n".join(lines), border_style=colour))
        return
    noun = "step" if len(results) == 1 else "steps"
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
    parser.add_argument("--dag-id", help="Airflow DAG ID for audit correlation")
    parser.add_argument("--dag-run-id", help="Airflow DAG run ID for audit correlation")
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
            f"[bold]Banking-Delta-Lakehouse daily pipeline[/bold]\n"
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
                status, detail = run_step(step, args.dag_id, args.dag_run_id)
            except KeyboardInterrupt:
                results.append(
                    StepResult(
                        step, FAILED, time.monotonic() - step_started, "interrupted"
                    )
                )
                raise
            except Exception as exc:  # noqa: BLE001 - never lose the summary to a crash
                status, detail = FAILED, f"{type(exc).__name__}: {_first_line(exc)}"
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
    # Anything not SUCCESS (failed OR never run, e.g. Ctrl+C between steps) is a bad exit.
    return 0 if all(r.status == SUCCESS for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
