"""Environment loading — the ONE place where .env is read.

Importing this module loads .env (if found) into os.environ without overriding
variables that are already set (so Airflow / CI / shell exports always win).
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import find_dotenv, load_dotenv

_dotenv_path = find_dotenv(usecwd=True)
if _dotenv_path:
    load_dotenv(_dotenv_path, override=False)

# Where local runtime files (.spark/ivy, .spark/tmp ...) live.
# Set PROJECT_ROOT in Airflow, where cwd is not the repo.
PROJECT_ROOT = Path(
    os.environ.get("PROJECT_ROOT") or (Path(_dotenv_path).parent if _dotenv_path else Path.cwd())
).resolve()


def require(name: str) -> str:
    """Return a required env var or fail with a clear message."""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value
