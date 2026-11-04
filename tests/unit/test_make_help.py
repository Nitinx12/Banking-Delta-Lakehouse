"""The help printer lists every Makefile target and needs no awk."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from scripts import make_help

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]


def _makefile_text() -> str:
    return (ROOT / "Makefile").read_text(encoding="utf-8")


def test_help_lists_every_declared_target():
    text = _makefile_text()
    listed = {name for _, name, _ in make_help.targets(text)}
    declared = set(re.findall(r"^([a-zA-Z][\w-]*):", text, re.MULTILINE))
    assert declared
    assert declared <= listed, sorted(declared - listed)


def test_help_keeps_the_groups_and_the_usage_line():
    rendered = make_help.render(_makefile_text())
    assert rendered.startswith('Usage: make <target> [ARGS="..."]')
    assert "\nStatic checks\n" in rendered
    assert "\nGate\n" in rendered


def test_help_target_does_not_call_awk():
    block = re.search(r"^help:.*(?:\n\t.*)*", _makefile_text(), re.MULTILINE)
    assert block, "Makefile has no help target"
    assert "awk" not in block.group(0)


def test_colour_wraps_only_the_target_label():
    rendered = make_help.render(_makefile_text(), colour=True)
    assert make_help._CYAN in rendered
    assert make_help._RESET in rendered


def test_no_colour_env_disables_ansi(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("NO_COLOR", "1")

    assert make_help.supports_colour(_Tty()) is False


def test_non_tty_disables_ansi(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("NO_COLOR", raising=False)

    assert make_help.supports_colour(_Tty(isatty=False)) is False


def test_tty_enables_ansi_when_vt_is_available(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("NO_COLOR", raising=False)
    monkeypatch.setattr(make_help, "_vt_enabled", lambda: True)

    assert make_help.supports_colour(_Tty()) is True


def test_main_writes_the_rendered_help(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(make_help, "supports_colour", lambda stream=None: False)

    assert make_help.main() == 0
    assert capsys.readouterr().out.startswith("Usage: make <target>")


class _Tty:
    def __init__(self, isatty: bool = True) -> None:
        self._isatty = isatty

    def isatty(self) -> bool:
        return self._isatty


class TestVtEnabled:
    def test_posix_always_enables(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(make_help.os, "name", "posix")

        assert make_help._vt_enabled() is True

    def test_missing_console_mode_disables(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(make_help.os, "name", "nt")
        monkeypatch.setitem(
            __import__("sys").modules, "ctypes", _ctypes(_Kernel32(False))
        )

        assert make_help._vt_enabled() is False

    def test_console_mode_is_enabled(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(make_help.os, "name", "nt")
        monkeypatch.setitem(
            __import__("sys").modules, "ctypes", _ctypes(_Kernel32(True))
        )

        assert make_help._vt_enabled() is True


def _ctypes(kernel32: "_Kernel32") -> object:
    from types import SimpleNamespace

    return SimpleNamespace(
        windll=SimpleNamespace(kernel32=kernel32),
        c_uint32=lambda: SimpleNamespace(value=0),
        byref=lambda obj: obj,
    )


class _Kernel32:
    def __init__(self, has_handle: bool) -> None:
        self.has_handle = has_handle

    def GetStdHandle(self, code: int) -> int:
        return -11

    def GetConsoleMode(self, handle: int, mode: object) -> bool:
        return self.has_handle

    def SetConsoleMode(self, handle: int, mode: int) -> bool:
        return True
