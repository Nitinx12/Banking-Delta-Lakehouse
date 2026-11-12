"""The Windows batch runner mirrors every Makefile target, and recipes stay portable."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.smoke

ROOT = Path(__file__).resolve().parents[2]

_CI_FORBIDDEN = (
    "sql-smoke",
    "integration",
    "smoke-live",
    "spark-smoke",
    "daily",
    "publish",
)

# Windows GNU Make runs recipes in cmd.exe, so neither shell's syntax may leak.
_RECIPE_FORBIDDEN = (
    (r"\$\$", "shell $ expansion (cmd.exe reads %VAR%)"),
    (r"%[A-Za-z_][A-Za-z0-9_]*%", "cmd.exe %VAR% expansion (bash reads $$VAR)"),
    (r"(?<![\w./-])(?:rm|find|ls|grep|sort|command)(?![\w-])", "POSIX-only command"),
    (r"/dev/null", "POSIX null device (cmd.exe uses nul)"),
    (r"\[\s+[\"'$]", "POSIX shell test bracket"),
    (r"Rscript -e '", "single-quoted Rscript expression (cmd.exe keeps the quotes)"),
)


def _makefile_text() -> str:
    return (ROOT / "Makefile").read_text(encoding="utf-8")


def _bat_text() -> str:
    return (ROOT / "tasks.bat").read_text(encoding="utf-8")


def _all_make_targets() -> set[str]:
    return set(re.findall(r"^([a-zA-Z][\w-]*):", _makefile_text(), re.MULTILINE))


def _make_targets() -> set[str]:
    """Declared targets except help, whose batch label the first test ignores."""
    return _all_make_targets() - {"help"}


def _batch_dispatch() -> set[str]:
    match = re.search(r"for %%T in \(([^)]*)\)", _bat_text())
    assert match, "tasks.bat has no dispatch list"
    return {name.lower() for name in match.group(1).split()}


def _batch_labels() -> set[str]:
    found = re.findall(r"^:t_([\w-]+)\s*$", _bat_text(), re.MULTILINE | re.IGNORECASE)
    return {name.lower() for name in found}


def _batch_block(label: str) -> str:
    lines = _bat_text().splitlines()
    start = next(
        i for i, line in enumerate(lines) if line.lower() == f":t_{label.lower()}"
    )
    block: list[str] = []
    for line in lines[start + 1 :]:
        if line.lower().startswith(":t_"):
            break
        block.append(line)
    return "\n".join(block)


def _batch_help_tokens() -> set[str]:
    tokens: set[str] = set()
    for line in _batch_block("help").splitlines():
        if not line.lower().startswith("echo ") or ":" not in line:
            continue
        tokens.update(line.split(":", 1)[1].split())
    return tokens


def _make_block(target: str) -> str:
    match = re.search(
        rf"^{re.escape(target)}:.*(?:\n\t.*)*", _makefile_text(), re.MULTILINE
    )
    assert match, f"Makefile has no {target} target"
    return match.group(0)


def _recipe_lines() -> list[str]:
    """Tab-indented lines after a real rule; skips .PHONY and the DC assignment."""
    recipes: list[str] = []
    in_recipe = False
    for line in _makefile_text().splitlines():
        if line.startswith("\t"):
            if in_recipe:
                recipes.append(line[1:])
        elif line.strip():
            in_recipe = bool(re.match(r"^[A-Za-z][\w-]*:", line))
    return recipes


def test_batch_runner_implements_every_make_target() -> None:
    labels = _batch_labels()
    missing = sorted(target for target in _make_targets() if target not in labels)
    assert not missing, f"tasks.bat is missing targets: {missing}"


def test_every_make_target_is_dispatchable() -> None:
    dispatch = _batch_dispatch()
    missing = sorted(_all_make_targets() - dispatch)
    assert not missing, f"dispatch list cannot reach: {missing}"


def test_every_batch_label_is_reachable() -> None:
    orphan = sorted(_batch_labels() - _batch_dispatch())
    assert not orphan, f"labels without a dispatch entry: {orphan}"


def test_batch_help_lists_every_target() -> None:
    tokens = _batch_help_tokens()
    missing = sorted(_all_make_targets() - tokens)
    assert not missing, f"tasks help does not list: {missing}"


def test_ci_target_is_hermetic() -> None:
    ci_block = re.search(r"^ci:.*(?:\n\t.*)*", _makefile_text(), re.MULTILINE)
    assert ci_block, "Makefile has no ci target"
    for forbidden in _CI_FORBIDDEN:
        assert forbidden not in ci_block.group(0), f"ci must not run {forbidden}"


def test_batch_ci_is_hermetic() -> None:
    block = _batch_block("ci").lower()
    for forbidden in _CI_FORBIDDEN:
        assert f":t_{forbidden}" not in block, f"batch ci must not run {forbidden}"


def test_every_make_target_is_phony() -> None:
    match = re.search(r"^\.PHONY:.*(?:\n\t.*)*", _makefile_text(), re.MULTILINE)
    assert match, "Makefile has no .PHONY declaration"
    body = match.group(0).replace(".PHONY:", "", 1)
    phony = set(re.findall(r"[\w-]+", re.sub(r"##.*", "", body)))
    missing = sorted(_all_make_targets() - phony)
    assert not missing, f"targets not declared .PHONY: {missing}"


def test_recipes_stay_portable_across_shells() -> None:
    recipes = _recipe_lines()
    assert recipes, "Makefile has no recipes"
    for pattern, why in _RECIPE_FORBIDDEN:
        offenders = [line for line in recipes if re.search(pattern, line)]
        assert not offenders, f"{why}: {offenders}"


def test_db_and_clean_targets_share_one_script() -> None:
    assert "scripts/apply_sql_smoke.py" in _make_block("sql-smoke")
    assert "scripts\\apply_sql_smoke.py" in _bat_text().lower()
    assert "scripts/clean.py" in _make_block("clean")
    assert "scripts/clean.py" in _make_block("report-clean")
    assert "scripts\\clean.py" in _bat_text().lower()


def test_every_make_target_dry_runs() -> None:
    """`make -n` must expand every recipe: guards, $(shell), target exports."""
    make = shutil.which("make")
    if not make or not shutil.which("git"):
        pytest.skip("make and git are required")
    targets = sorted(_all_make_targets())
    if not shutil.which("gitleaks"):
        targets.remove("leaks")  # its guard fails whenever the tool is absent
    env = dict(os.environ, ALLOW_SQL_SMOKE="1")
    result = subprocess.run(
        [make, "-n", *targets],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=300,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_integration_guard_fires_without_the_flag() -> None:
    make = shutil.which("make")
    if not make:
        pytest.skip("make is not installed")
    env = dict(os.environ)
    env.pop("ALLOW_SQL_SMOKE", None)
    result = subprocess.run(
        [make, "-n", "integration"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
        check=False,
    )
    assert result.returncode != 0
    assert "ALLOW_SQL_SMOKE" in result.stderr


def test_leaks_guard_names_the_missing_tool() -> None:
    make = shutil.which("make")
    if not make or shutil.which("gitleaks"):
        pytest.skip("make is installed and gitleaks is not")
    result = subprocess.run(
        [make, "-n", "leaks"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
        check=False,
    )
    assert result.returncode != 0
    assert "gitleaks not found" in result.stderr
