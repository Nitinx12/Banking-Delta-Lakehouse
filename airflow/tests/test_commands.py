"""Command builders: no secrets, correct interpreter, exec/forwarding."""

from __future__ import annotations

import os
import re

import pytest
from banking_airflow import commands

pytestmark = pytest.mark.unit


def test_banking_cmd_uses_exec_cd_and_banking_python():
    cmd = commands.banking_cmd("main.py --only raw-tests")
    assert "exec " in cmd
    assert f'cd "{commands.BANKING_HOME}"' in cmd
    assert commands.BANKING_PYTHON in cmd
    assert "set -euo pipefail" in cmd


def test_run_env_is_secret_free():
    offenders = [
        k
        for k in commands.RUN_ENV
        if re.search(r"PASS|TOKEN|SECRET|KEY", k, re.IGNORECASE)
    ]
    assert offenders == []


def test_run_env_sets_clean_logging():
    assert commands.RUN_ENV["NO_COLOR"] == "1"
    assert commands.RUN_ENV["PYTHONUTF8"] == "1"
    assert commands.RUN_ENV["TERM"] == "dumb"


def test_run_env_pythonpath_lets_preflight_import_src():
    paths = commands.RUN_ENV["PYTHONPATH"].split(os.pathsep)
    assert f"{commands.BANKING_HOME}/src" in paths
    assert "/opt/airflow/include" in paths


def test_extract_cmd_passes_run_id_and_defers_finalize():
    cmd = commands.extract_cmd("mongo")
    assert "--sources mongo" in cmd
    assert "{{ dag.dag_id }}" in cmd
    assert "{{ run_id }}" in cmd
    assert "--finalize" not in cmd


def test_publish_cmd_defers_finalize_and_honours_full_param():
    cmd = commands.publish_cmd()
    assert "--finalize" not in cmd
    assert "params.publish_full" in cmd


def test_finalize_cmd_targets_the_audit_module():
    assert commands.finalize_cmd() == "-m banking_airflow.finalize_audit"


@pytest.mark.parametrize(
    "step, expected",
    [
        (
            "raw-tests",
            "main.py --only raw-tests --dag-id {{ dag.dag_id }} --dag-run-id '{{ run_id }}'",
        ),
        ("staging-load", "main.py --only staging-load"),
        (
            "marts-tests",
            "main.py --only marts-tests --dag-id {{ dag.dag_id }} --dag-run-id '{{ run_id }}'",
        ),
    ],
)
def test_load_or_test_cmd(step, expected):
    assert commands.load_or_test_cmd(step) == expected


@pytest.mark.parametrize(
    "kind, expected_parts",
    [
        (
            "daily",
            [
                "-m reports.scripts.build",
                "--kind daily",
                "--dag-id {{ dag.dag_id }}",
                "--dag-run-id '{{ run_id }}'",
            ],
        ),
        (
            "incident",
            [
                "-m reports.scripts.build",
                "--kind incident",
                "--dag-id {{ dag.dag_id }}",
                "--dag-run-id '{{ run_id }}'",
            ],
        ),
        (
            "weekly",
            [
                "-m reports.scripts.build",
                "--kind weekly",
                "--dag-id {{ dag.dag_id }}",
                "--dag-run-id '{{ run_id }}'",
            ],
        ),
    ],
)
def test_report_command_composed(kind, expected_parts):
    """Regression test for I-05: report_command() composes correctly without
    a leading 'python' and with -m module syntax."""
    import shlex

    cmd = commands.report_command(kind)
    tokens = shlex.split(cmd)
    # Should use -m module syntax, not bare 'python'
    assert tokens[0] == "-m"
    assert tokens[1] == "reports.scripts.build"
    # All expected parts should be present
    for part in expected_parts:
        assert part in cmd
