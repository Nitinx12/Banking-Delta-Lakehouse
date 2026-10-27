"""Transient Databricks failures are retried with backoff; real errors are not."""

from __future__ import annotations

import pytest

from src.utils import connection
from src.utils.connection import databricks_transient, dbx_call

pytestmark = pytest.mark.unit

_CAPACITY = "Error during request to server: BAD_REQUEST: Cannot create the resource, please try again later."


class _FakeTime:
    """Records requested sleeps instead of waiting."""

    def __init__(self) -> None:
        self.sleeps: list[float] = []

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)


@pytest.fixture
def clock(monkeypatch: pytest.MonkeyPatch) -> _FakeTime:
    fake = _FakeTime()
    monkeypatch.setattr(connection, "time", fake)
    return fake


def test_transient_error_is_retried_until_it_succeeds(clock: _FakeTime) -> None:
    attempts = 0

    def flaky() -> str:
        nonlocal attempts
        attempts += 1
        if attempts < 3:
            raise RuntimeError(_CAPACITY)
        return "rows"

    assert dbx_call("public.loans", flaky) == "rows"
    assert attempts == 3
    assert clock.sleeps == [5.0, 10.0], "exponential backoff between attempts"


def test_non_transient_error_fails_immediately(clock: _FakeTime) -> None:
    attempts = 0

    def broken() -> None:
        nonlocal attempts
        attempts += 1
        raise ValueError("Unsafe or empty Databricks identifier: '; drop")

    with pytest.raises(ValueError):
        dbx_call("public.loans", broken)
    assert attempts == 1
    assert clock.sleeps == []


def test_transient_error_gives_up_after_the_attempt_budget(
    clock: _FakeTime, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("DATABRICKS_MAX_ATTEMPTS", "2")
    monkeypatch.setenv("DATABRICKS_RETRY_BASE_SECONDS", "1")
    attempts = 0

    def always_down() -> None:
        nonlocal attempts
        attempts += 1
        raise RuntimeError(_CAPACITY)

    with pytest.raises(RuntimeError):
        dbx_call("public.loans", always_down)
    assert attempts == 2
    assert clock.sleeps == [1.0]


def test_retry_budget_is_capped(
    clock: _FakeTime, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("DATABRICKS_MAX_ATTEMPTS", "4")
    monkeypatch.setenv("DATABRICKS_RETRY_BASE_SECONDS", "30")

    def always_down() -> None:
        raise RuntimeError(_CAPACITY)

    with pytest.raises(RuntimeError):
        dbx_call("public.loans", always_down)
    assert clock.sleeps == [30.0, 60.0, 60.0], "backoff never exceeds 60s"


def test_connection_failures_count_as_transient() -> None:
    assert databricks_transient(ConnectionResetError("reset"))
    assert databricks_transient(TimeoutError("timed out"))
    assert databricks_transient(RuntimeError("RESOURCE_EXHAUSTED"))
    assert not databricks_transient(ValueError("Bad timestamp watermark"))
