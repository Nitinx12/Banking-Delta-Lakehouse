"""Preflight backs off against a down source and fails fast on bad credentials."""

from __future__ import annotations

import pytest

import main
from src.utils import preflight

pytestmark = pytest.mark.unit


class _Clock:
    """Virtual clock: recorded sleeps advance time instead of waiting."""

    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


@pytest.fixture
def clock(monkeypatch: pytest.MonkeyPatch) -> _Clock:
    fake = _Clock()
    monkeypatch.setattr(preflight, "time", fake)
    return fake


def test_healthy_source_is_probed_once(clock: _Clock) -> None:
    """First green attempt: no sleeping, no retries."""
    attempts: list[int] = []

    def check() -> None:
        attempts.append(1)

    preflight.wait_until("postgresql", check, timeout=60, base=1, cap=10)

    assert len(attempts) == 1
    assert clock.sleeps == []


def test_transient_failure_retries_with_capped_backoff(clock: _Clock) -> None:
    """A source that comes back gets exponential sleeps, each under the cap."""
    failures = {"left": 3}

    def check() -> None:
        if failures["left"]:
            failures["left"] -= 1
            raise ConnectionError("warehouse is starting")

    preflight.wait_until("databricks", check, timeout=300, base=2, cap=30)

    assert failures["left"] == 0
    assert len(clock.sleeps) == 3
    assert all(0 < nap <= 30 for nap in clock.sleeps)


@pytest.mark.parametrize(
    "message",
    [
        # live message for a rejected Databricks token (2026-11-05)
        "Error during request to server: : Credential was not sent or was of an"
        " unsupported type for this API.",
        "[Databricks] ERROR: HttpError 401: invalid access token",
        "HTTP 403: permission denied",
        'password authentication failed for user "postgres"',
    ],
)
def test_auth_error_fails_immediately(clock: _Clock, message: str) -> None:
    """A rejected token never heals: no sleep, PreflightError, last error kept."""
    attempts: list[int] = []

    def check() -> None:
        attempts.append(1)
        raise RuntimeError(message)

    with pytest.raises(preflight.PreflightError) as excinfo:
        preflight.wait_until("databricks", check, timeout=300, base=2, cap=30)

    assert message in str(excinfo.value)
    assert len(attempts) == 1
    assert clock.sleeps == []


def test_keeps_retrying_until_the_deadline(clock: _Clock) -> None:
    """The budget is wall-clock: give up at timeout with the last error attached."""

    def check() -> None:
        raise TimeoutError("resource is unavailable")

    with pytest.raises(TimeoutError) as excinfo:
        preflight.wait_until("mongodb", check, timeout=5, base=1, cap=2)

    assert "no answer within 5s" in str(excinfo.value)
    assert "resource is unavailable" in str(excinfo.value)
    assert clock.now >= 5
    assert len(clock.sleeps) >= 3


def test_probe_order_and_budgets(monkeypatch: pytest.MonkeyPatch) -> None:
    """The warehouse is checked first; databricks gets the longest budget."""
    monkeypatch.setenv("PREFLIGHT_TIMEOUT", "45")
    monkeypatch.setenv("PREFLIGHT_DATABRICKS_TIMEOUT", "120")

    probes = preflight.probes()

    assert [probe.name for probe in probes] == [
        "postgresql",
        "mysql",
        "mongodb",
        "databricks",
    ]
    assert [probe.timeout for probe in probes] == [45.0, 45.0, 45.0, 120.0]


def test_preflight_runs_before_every_other_step() -> None:
    """Step 1: no source may be touched before it answers."""
    names = [step.name for step in main.build_steps()]

    assert names[0] == "preflight"
    assert "raw-inject" in names


def test_run_step_calls_run_preflight(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[int] = []
    monkeypatch.setattr(main, "run_preflight", lambda: calls.append(1))

    status, detail = main.run_step(main.build_steps()[0])

    assert (status, detail) == (main.SUCCESS, "")
    assert calls == [1]


def test_dead_source_stops_the_run_with_exit_one(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Preflight raising must surface as a failed step, never a traceback."""
    step = main.Step("preflight", "sources", "probe")
    monkeypatch.setattr(main, "build_steps", lambda: (step,))

    def boom() -> None:
        raise RuntimeError("postgresql: no answer within 60s")

    monkeypatch.setattr(main, "run_preflight", boom)

    assert main.main([]) == 1
