# LaTeX safe Jinja environment for the report templates.
from __future__ import annotations

from pathlib import Path
from typing import Any

import jinja2

_TEX_MAP = {
    "\\": r"\textbackslash{}",
    "&": r"\&",
    "%": r"\%",
    "$": r"\$",
    "#": r"\#",
    "_": r"\_",
    "{": r"\{",
    "}": r"\}",
    "~": r"\textasciitilde{}",
    "^": r"\textasciicircum{}",
}

_STATE_COLOURS = {"ok": "ok", "warn": "warn", "bad": "bad", "idle": "idle"}
_SEVERITY_COLOURS = {
    "INFO": "ok",
    "MINOR": "warn",
    "MAJOR": "bad",
    "CRITICAL": "crit",
    "UNKNOWN": "idle",
}


class RawTeX(str):
    """Opt out of escaping for Python built LaTeX only."""


def tex_escape(value: object) -> str:
    """Escape every LaTeX special character; RawTeX passes through."""
    if isinstance(value, RawTeX):
        return str(value)
    text = "" if value is None else str(value)
    return "".join(_TEX_MAP.get(ch, ch) for ch in text)


def ident(value: object) -> RawTeX:
    """Break long identifiers (dots, underscores) across lines."""
    text = tex_escape(value)
    return RawTeX(
        text.replace(r"\_", r"\_\allowbreak{}").replace(".", r".\allowbreak{}")
    )


def fmt_int(value: object) -> RawTeX:
    """Thin space thousands separators."""
    if value is None:
        return RawTeX("n/a")
    if not _is_number(value):
        return RawTeX(tex_escape(value))
    return RawTeX(f"{int(value):,}".replace(",", r"\,"))


def fmt_pct(value: object) -> RawTeX:
    """One decimal percentage, or n/a."""
    if value is None:
        return RawTeX("n/a")
    return RawTeX(f"{100.0 * float(value):.1f}\\%")


def fmt_dur(value: object) -> str:
    """Human duration such as 1h 05m or 42s."""
    if value is None:
        return "n/a"
    seconds = int(value)
    if seconds < 60:
        return f"{seconds}s"
    minutes, sec = divmod(seconds, 60)
    hours, minute = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minute:02d}m"
    return f"{minutes}m {sec:02d}s"


def fmt_ts(value: object) -> str:
    """Timestamp as stored, space instead of T, with its zone label."""
    if value is None:
        return "n/a"
    return str(value).replace("T", " ")


def state_colour(state: object) -> str:
    """Named TikZ state colour; unknown states map to idle."""
    return _STATE_COLOURS.get(str(state), "idle")


def severity_colour(severity: object) -> str:
    """Named severity colour stem; unknown severities map to idle."""
    return _SEVERITY_COLOURS.get(str(severity), "idle")


def status_colour(status: object) -> str:
    """Run or table status to a palette colour stem such as ok or bad."""
    return {
        "SUCCESS": "ok",
        "PARTIAL": "warn",
        "FAILED": "bad",
        "SKIPPED": "idle",
        "RUNNING": "idle",
        "WARNING": "warn",
        "PASS": "ok",
        "FAIL": "bad",
    }.get(str(status), "idle")


def plural(value: object, singular: str, plural_form: str | None = None) -> str:
    """1 item, 2 items style choice."""
    word = plural_form or f"{singular}s"
    return singular if value == 1 else word


FILTERS: dict[str, Any] = {
    "fmt_int": fmt_int,
    "fmt_pct": fmt_pct,
    "fmt_dur": fmt_dur,
    "fmt_ts": fmt_ts,
    "state_colour": state_colour,
    "severity_colour": severity_colour,
    "status_colour": status_colour,
    "plural": plural,
    "raw": RawTeX,
    "ident": ident,
}


def _is_number(value: object) -> bool:
    return isinstance(value, int | float) and not isinstance(value, bool)


def make_env(*template_dirs: Path) -> jinja2.Environment:
    """Custom delimiter environment; every output is escaped by finalize."""
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader([str(p) for p in template_dirs]),
        block_start_string=r"\BLOCK{",
        block_end_string="}",
        variable_start_string=r"\VAR{",
        variable_end_string="}",
        comment_start_string=r"\#{",
        comment_end_string="}",
        line_statement_prefix="%%",
        line_comment_prefix="%#",
        trim_blocks=True,
        lstrip_blocks=True,
        autoescape=False,
        undefined=jinja2.StrictUndefined,
    )
    env.finalize = tex_escape
    env.filters.update(FILTERS)
    return env
