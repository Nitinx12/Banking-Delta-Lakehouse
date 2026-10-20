"""Shared fixtures for tests/: fake config and a hard no-network guarantee.

Config is read only in src/utils/config.py (override=False), so exporting fake
values before the code under test runs is enough to isolate it from .env.
"""

from __future__ import annotations

import socket
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

FAKE_ENV = {
    "ENVIRONMENT": "test",
    "PG_HOST": "localhost",
    "PG_PORT": "5432",
    "PG_DB": "banking_delta_test",
    "PG_USER": "test",
    "PG_PASS": "test-only",
    "MYSQL_HOST": "localhost",
    "MYSQL_PORT": "3306",
    "MYSQL_USER": "test",
    "MYSQL_PASSWORD": "test-only",
    "MYSQL_DB": "banking_core_db_test",
    "MONGO_URI": "mongodb://localhost:27017",
    "MONGO_DB_NAME": "banking_support_db_test",
    "DATABRICKS_HOST": "example.invalid",
    "DATABRICKS_TOKEN": "test-only",
    "DATABRICKS_HTTP_PATH": "/sql/test",
    "DATABRICKS_CATALOG": "test",
}


@pytest.fixture
def fake_env(monkeypatch: pytest.MonkeyPatch) -> dict[str, str]:
    """Deterministic config; real shell/.env values cannot leak into a test."""
    for key, value in FAKE_ENV.items():
        monkeypatch.setenv(key, value)
    return dict(FAKE_ENV)


@pytest.fixture(autouse=True)
def no_network(request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch) -> None:
    """unit/smoke tests must never open a socket — fake the driver instead."""
    if not (
        request.node.get_closest_marker("unit")
        or request.node.get_closest_marker("smoke")
    ):
        return

    def _blocked(*_args: object, **_kwargs: object) -> None:
        raise RuntimeError("network access is forbidden in unit/smoke tests")

    monkeypatch.setattr(socket.socket, "connect", _blocked)
