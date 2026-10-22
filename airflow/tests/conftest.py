"""Shared test setup: no DB, no Spark, no network.

Adds `airflow/include` (so `banking_airflow` imports) and the repo root (so
`reports.*` resolves), points the DagBag at `airflow/dags`, and keeps tests
import-safe on Windows dev boxes.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

AIRFLOW_DIR = Path(__file__).resolve().parent.parent
INCLUDE_DIR = AIRFLOW_DIR / "include"
DAGS_DIR = AIRFLOW_DIR / "dags"
REPO_ROOT = AIRFLOW_DIR.parent

for path in (str(INCLUDE_DIR), str(AIRFLOW_DIR), str(REPO_ROOT)):
    if path not in sys.path:
        sys.path.insert(0, path)

os.environ.setdefault("AIRFLOW__CORE__LOAD_EXAMPLES", "False")
os.environ.setdefault("AIRFLOW__CORE__UNIT_TEST_MODE", "True")
os.environ.setdefault("AIRFLOW__CORE__DAGS_FOLDER", str(DAGS_DIR))
# parse-timeout uses signal.setitimer (POSIX only); 0 = no timeout, tests parse fast
os.environ.setdefault("AIRFLOW__CORE__DAGBAG_IMPORT_TIMEOUT", "0")
os.environ.setdefault("BANKING_HOME", str(AIRFLOW_DIR.parent))

# airflow.sdk.io calls os.register_at_fork (POSIX only) during DagBag import.
# Windows has no such attribute, and stdlib modules guard on its absence while
# reinit helpers only exist on POSIX — so initialise those modules first, then
# no-op the hook for airflow. Linux CI never enters this branch.
if not hasattr(os, "register_at_fork"):
    import concurrent.futures.process  # noqa: F401
    import concurrent.futures.thread  # noqa: F401
    import multiprocessing  # noqa: F401

    os.register_at_fork = lambda **_kwargs: None  # type: ignore[attr-defined]

# dag_processing.bundles imports fcntl at module level; import-only stub, the
# DagBag tests never take the file locks.
if os.name == "nt" and "fcntl" not in sys.modules:
    import types

    _fcntl = types.ModuleType("fcntl")
    _fcntl.flock = lambda *_args, **_kwargs: None  # type: ignore[attr-defined]
    _fcntl.LOCK_EX = _fcntl.LOCK_NB = _fcntl.LOCK_SH = _fcntl.LOCK_UN = 0  # type: ignore[attr-defined]
    sys.modules["fcntl"] = _fcntl
