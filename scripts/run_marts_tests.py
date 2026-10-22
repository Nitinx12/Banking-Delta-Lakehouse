"""scripts/run_marts_tests.py - run the marts-schema data-quality SQL tests with rich output.

Discovers ``tests/data-quality/marts/*.sql`` in numeric order, creates/refreshes each test's
audit procedure, then ``CALL``s it against the PostgreSQL warehouse. Every run is logged to
``audit.dq_run``/``audit.dq_violation`` by the procedures themselves; this script prints a
live progress bar, a pass/fail summary table, and the latest audit result per test. Exits 0
only if every test passed.

    python scripts/run_marts_tests.py                 # run every marts test
    python scripts/run_marts_tests.py --only 09       # run tests whose name matches "09"
    python scripts/run_marts_tests.py --master        # run 00_master_marts_tests.sql only
    python scripts/run_marts_tests.py -v              # also print each test's NOTICE lines
    python scripts/run_marts_tests.py --list          # list discovered tests and exit
    python scripts/run_marts_tests.py --dag-id ... --dag-run-id ...  # Airflow integration
"""

from __future__ import annotations

import argparse
import re
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from rich.console import Console
from rich.panel import Panel
from rich.progress import (
    BarColumn,
    Progress,
    SpinnerColumn,
    TaskProgressColumn,
    TextColumn,
    TimeElapsedColumn,
)
from rich.table import Table
from rich.text import Text

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from utils.connection import get_pg_connection

REPO_ROOT: Path = Path(__file__).resolve().parents[1]
TEST_DIR: Path = REPO_ROOT / "tests" / "data-quality" / "marts"

console = Console()


@dataclass
class TestResult:
    """Outcome of a single SQL data-quality test."""

    name: str
    passed: bool
    seconds: float
    error: str | None = None
    notices: list[str] = field(default_factory=list)


def discover_tests(only: str | None, master: bool = False) -> list[Path]:
    """Return test files in numeric order; master files are excluded unless requested."""
    tests = sorted(
        t for t in TEST_DIR.glob("*.sql") if t.name.startswith("00_master_") == master
    )
    if only:
        tests = [t for t in tests if only in t.name]
    return tests


def run_test(conn, path: Path, pipeline_run_id: uuid.UUID | None) -> TestResult:
    """Execute one test file and capture timing, notices, and any violation error."""
    name = path.name
    sql = path.read_text()
    proc = re.search(r"PROCEDURE\s+([\w.]+)\s*\(", sql)
    del conn.notices[:]
    start = time.perf_counter()
    try:
        with conn.cursor() as cur:
            if proc:
                cur.execute(sql)  # CREATE OR REPLACE PROCEDURE (autocommit commits it)
                if pipeline_run_id:
                    cur.execute(
                        f"CALL {proc.group(1)}(p_pipeline_run_id => %s)",
                        (pipeline_run_id,),
                    )
                else:
                    cur.execute(f"CALL {proc.group(1)}()")
            else:
                cur.execute(sql)
        passed = True
        error = None
    except Exception as exc:  # noqa: BLE001 - a DB error is the test failure we want to report
        passed = False
        error = str(exc).strip()
    elapsed = time.perf_counter() - start
    notices = [line for line in (n.strip() for n in conn.notices) if line]
    return TestResult(
        name=name, passed=passed, seconds=elapsed, error=error, notices=notices
    )


def _status_text(result: TestResult) -> Text:
    return (
        Text("PASS", style="bold green")
        if result.passed
        else Text("FAIL", style="bold red")
    )


def _build_summary(results: list[TestResult]) -> Table:
    table = Table(show_header=True, header_style="bold cyan", box=None, pad_edge=False)
    table.add_column("#", style="dim", justify="right")
    table.add_column("Test", style="white")
    table.add_column("Status", justify="center")
    table.add_column("Time", justify="right", style="dim")
    table.add_column("Result", overflow="fold")

    for idx, result in enumerate(results, start=1):
        outcome = "clean" if result.passed else f"{len(result.notices)} notice(s)"
        table.add_row(
            str(idx),
            result.name,
            _status_text(result),
            f"{result.seconds:.1f}s",
            outcome,
        )
    return table


def _print_failures(results: list[TestResult]) -> None:
    for result in results:
        if result.passed:
            continue
        body = Text()
        body.append(result.error or "unknown failure", style="red")
        console.print(
            Panel(body, title=f"[red]{result.name}[/red]", border_style="red")
        )


def _print_audit(conn) -> None:
    """Print the latest audit.dq_run row for each test recorded by the procedures."""
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT script_name, status, violation_count, finished_at "
                "FROM audit.v_dq_latest ORDER BY script_name"
            )
            rows = cur.fetchall()
    except Exception:  # noqa: BLE001 - audit is best-effort reporting, never gate the run
        return
    if not rows:
        return
    table = Table(
        title="Latest audit (audit.v_dq_latest)",
        show_header=True,
        header_style="bold cyan",
        box=None,
        pad_edge=False,
    )
    table.add_column("Test", style="white")
    table.add_column("Status", justify="center")
    table.add_column("Violations", justify="right")
    table.add_column("Finished", style="dim")
    for script_name, status, count, finished in rows:
        colour = "green" if status == "PASS" else "red"
        table.add_row(
            script_name,
            Text(status, style=f"bold {colour}"),
            str(count),
            finished.isoformat(sep=" ", timespec="seconds") if finished else "-",
        )
    console.print()
    console.print(table)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run the marts-schema data-quality SQL tests."
    )
    parser.add_argument("--only", help="substring to filter test filenames (e.g. 09)")
    parser.add_argument(
        "--master",
        action="store_true",
        help="run only the master procedure (executes all tests in order)",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="print each test's NOTICE lines"
    )
    parser.add_argument(
        "--list", action="store_true", help="list discovered tests and exit"
    )
    parser.add_argument("--dag-id", help="Airflow DAG ID for audit correlation")
    parser.add_argument("--dag-run-id", help="Airflow DAG run ID for audit correlation")
    args = parser.parse_args(argv)

    tests = discover_tests(args.only, master=args.master)
    if not tests:
        console.print(f"[red]No tests found in {TEST_DIR}[/red]")
        return 1
    if args.list:
        for path in tests:
            console.print(f"  {path.name}")
        return 0

    scope = "master procedure" if args.master else f"{len(tests)} tests"
    console.print(
        Panel.fit(
            f"[bold]Marts Schema Data-Quality Gate[/bold]\n"
            f"[dim]{TEST_DIR}[/dim]  |  [cyan]schema marts[/cyan]  |  [cyan]{scope}[/cyan]",
            border_style="cyan",
        )
    )

    pipeline_run_id = None
    if args.dag_id and args.dag_run_id:
        from utils.audit import start_pipeline_run

        pipeline_run_id = start_pipeline_run(
            dag_id=args.dag_id,
            dag_run_id=args.dag_run_id,
            trigger_type="airflow",
        )

    try:
        conn = get_pg_connection(application_name="run_marts_tests")
    except Exception as exc:  # noqa: BLE001
        console.print(
            Panel(str(exc), title="[red]Connection failed[/red]", border_style="red")
        )
        return 2
    conn.autocommit = True

    results: list[TestResult] = []
    progress = Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
        TimeElapsedColumn(),
        console=console,
    )

    try:
        with progress:
            task = progress.add_task("running", total=len(tests))
            for path in tests:
                progress.update(task, description=f"[cyan]{path.name}[/cyan]")
                result = run_test(conn, path, pipeline_run_id)
                results.append(result)
                if args.verbose and result.notices:
                    for notice in result.notices:
                        progress.console.print(f"    [dim]{notice}[/dim]")
                progress.advance(task)

        _print_audit(conn)
    finally:
        conn.close()

    console.print()
    console.print(_build_summary(results))
    _print_failures(results)

    passed = sum(1 for r in results if r.passed)
    failed = len(results) - passed
    if failed:
        console.print(
            Panel(
                f"[red bold]{failed} of {len(results)} tests failed[/red bold]",
                border_style="red",
            )
        )
        return 1

    console.print(
        Panel(
            f"[green bold]All {len(results)} marts data-quality tests passed[/green bold]",
            border_style="green",
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
