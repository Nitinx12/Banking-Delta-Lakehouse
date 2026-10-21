"""Command builders shared by DAGs. Contains NO secrets."""

from __future__ import annotations

import os

BANKING_HOME = os.environ.get("BANKING_HOME", "/opt/banking")
BANKING_PYTHON = os.environ.get("BANKING_PYTHON", "/opt/banking-venv/bin/python")

# Non-secret environment for every pipeline subprocess. Secrets arrive through
# the container environment (BashOperator append_env=True).
RUN_ENV: dict[str, str] = {
    "PYTHONPATH": os.pathsep.join(
        (
            f"{BANKING_HOME}",
            f"{BANKING_HOME}/src",
            "/opt/airflow/include",
        )
    ),
    "PYTHONUNBUFFERED": "1",
    "PYTHONUTF8": "1",
    "NO_COLOR": "1",
    "TERM": "dumb",
    "CORPUS_PATH": f"{BANKING_HOME}/data/corpus",
    "CORPUS_PARQUET_DIR": f"{BANKING_HOME}/data/parquet",
}


def banking_cmd(args: str) -> str:
    """Run the project interpreter from the project root; `exec` forwards SIGTERM to Python."""
    return f'set -euo pipefail\ncd "{BANKING_HOME}"\nexec "{BANKING_PYTHON}" {args}\n'


# run_jobs.py accepts --dag-id/--dag-run-id and forwards them to each extract
# job, so the three parallel sources share ONE audit.pipeline_runs row.
def extract_cmd(source: str) -> str:
    """Per-source extract command (source is the run_jobs.py `--sources` value)."""
    return (
        f"scripts/run_jobs.py --sources {source} "
        "--dag-id {{ dag.dag_id }} --dag-run-id '{{ run_id }}'"
    )


def load_or_test_cmd(step: str) -> str:
    """`main.py --only <step>` for a load or DQ step."""
    return f"main.py --only {step}"


def publish_cmd() -> str:
    """Publish marts; finalize_audit closes the shared pipeline run afterwards."""
    return (
        "src/jobs/publish_marts.py --dag-id {{ dag.dag_id }} "
        "--dag-run-id '{{ run_id }}' "
        "{% if params.publish_full %}--full{% endif %}"
    )


def finalize_cmd() -> str:
    """Close this DAG run's audit.pipeline_runs row exactly once, at the end."""
    return "-m banking_airflow.finalize_audit"


def report_command(kind: str = "daily") -> str:
    """Build the report for a DAG run. Uses the same audit data as finalize_audit."""
    return (
        f"python -m reports.scripts.build --kind {kind} "
        "--dag-id {{ dag.dag_id }} --dag-run-id '{{ run_id }}'"
    )
