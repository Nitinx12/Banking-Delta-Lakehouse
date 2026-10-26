"""main.py must return a failing exit code whenever a step fails."""

from __future__ import annotations

import pytest

import main

pytestmark = pytest.mark.unit


def _only_step() -> main.Step:
    return main.Step("raw-inject", "raw", "fake step")


def test_ci_keep_going_still_fails_on_failed_step(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """CI=true must not launder a failed step into exit 0."""
    monkeypatch.setenv("CI", "true")
    monkeypatch.setattr(main, "build_steps", lambda: (_only_step(),))
    monkeypatch.setattr(main, "run_step", lambda *args: (main.FAILED, "boom"))

    assert main.main(["--keep-going"]) == 1


def test_ci_keep_going_passes_when_all_steps_succeed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A genuinely clean run still exits 0 in CI."""
    monkeypatch.setenv("CI", "true")
    monkeypatch.setattr(main, "build_steps", lambda: (_only_step(),))
    monkeypatch.setattr(main, "run_step", lambda *args: (main.SUCCESS, ""))

    assert main.main(["--keep-going"]) == 0
