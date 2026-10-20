"""Every production module imports with no DB, no network and no Spark."""

from __future__ import annotations

import importlib
import pkgutil
from pathlib import Path

import pytest

pytestmark = pytest.mark.smoke

ROOT = Path(__file__).resolve().parents[2]

# Connects to Postgres at import time (no main guard); never import it in tests.
_SKIP = {"scripts.list_raw_columns"}

# dashboard/app.py and dashboard/pages/* are Streamlit scripts: importing one
# executes it (page config, sidebar, chart rendering), so only their libraries
# are import-smoke-tested. They import `helpers.*` / `lib.*` as top-level
# names, which Streamlit makes work by putting dashboard/ on sys.path.
_PACKAGES = ["src", "scripts", "helpers", "lib"]


def _module_names(package: str) -> list[str]:
    pkg = importlib.import_module(package)
    names = [package]
    if hasattr(pkg, "__path__"):
        names += [
            m.name for m in pkgutil.walk_packages(pkg.__path__, prefix=f"{package}.")
        ]
    return names


@pytest.mark.parametrize("package", _PACKAGES)
def test_package_modules_import(package: str, monkeypatch: pytest.MonkeyPatch) -> None:
    if package in ("helpers", "lib"):
        monkeypatch.syspath_prepend(str(ROOT / "dashboard"))
    failures = []
    for name in _module_names(package):
        if name in _SKIP:
            continue
        try:
            importlib.import_module(name)
        except Exception as exc:  # collect all failures, not just the first
            failures.append(f"{name}: {type(exc).__name__}: {exc}")
    assert not failures, failures
