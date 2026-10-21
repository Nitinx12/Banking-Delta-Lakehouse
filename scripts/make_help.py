"""scripts/make_help.py - print the Makefile targets for `make help`.

The Makefile holds the target list; this script reads it and prints the groups,
the targets and their one-line description. It replaces the awk one-liner so
`make help` also works on Windows, where GNU Make runs the recipe in cmd.exe
and no awk is installed.

    uv run python scripts/make_help.py
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from typing import TextIO

ROOT = Path(__file__).resolve().parents[1]
MAKEFILE = ROOT / "Makefile"

_GROUP = re.compile(r"^##@\s*(.+?)\s*$")
_TARGET = re.compile(r"^([A-Za-z][\w-]*):.*##[ \t]*(.+?)\s*$")

_CYAN = "\033[36m"
_RESET = "\033[0m"
_NAME_WIDTH = 14


def targets(text: str) -> list[tuple[str, str, str]]:
    """(group, target, description) for every documented target, in file order."""
    found: list[tuple[str, str, str]] = []
    group = ""
    for line in text.splitlines():
        header = _GROUP.match(line)
        if header:
            group = header.group(1)
            continue
        target = _TARGET.match(line)
        if target:
            found.append((group, target.group(1), target.group(2)))
    return found


def _vt_enabled() -> bool:
    """True when the Windows console takes ANSI escapes."""
    if os.name != "nt":
        return True
    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        handle = kernel32.GetStdHandle(-11)
        mode = ctypes.c_uint32()
        if not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            return False
        return bool(kernel32.SetConsoleMode(handle, mode.value | 0x0004))
    except Exception:  # noqa: BLE001 - colour is optional, never fatal
        return False


def supports_colour(stream: TextIO = sys.stdout) -> bool:
    """ANSI colour only for a terminal that understands it."""
    if os.environ.get("NO_COLOR"):
        return False
    if not stream.isatty():
        return False
    return _vt_enabled()


def render(text: str, colour: bool = False) -> str:
    """The help text for one Makefile."""
    lines = ['Usage: make <target> [ARGS="..."]']
    group = ""
    for name_group, name, description in targets(text):
        if name_group != group:
            group = name_group
            lines.extend(["", group])
        label = f"{name:<{_NAME_WIDTH}}"
        if colour:
            label = f"{_CYAN}{label}{_RESET}"
        lines.append(f"  {label}  {description}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    """Print the help text; returns the exit code."""
    sys.stdout.write(render(MAKEFILE.read_text(encoding="utf-8"), supports_colour()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
