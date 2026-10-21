"""LaTeX escaping, RawTeX passthrough and the strict Jinja environment."""

from __future__ import annotations

import jinja2
import pytest

from reports.scripts import render
from reports.scripts.paths import REPORTS_DIR

pytestmark = pytest.mark.unit


def test_tex_escape_covers_every_special() -> None:
    assert render.tex_escape(r"a&b%c$d#e_f{g}h~i^j") == (
        r"a\&b\%c\$d\#e\_f\{g\}h\textasciitilde{}i\textasciicircum{}j"
    )
    assert render.tex_escape("back\\slash") == r"back\textbackslash{}slash"


def test_tex_escape_none_is_empty() -> None:
    assert render.tex_escape(None) == ""


def test_rawtex_passes_through_finalize() -> None:
    env = render.make_env(REPORTS_DIR / "template")
    assert env.finalize(render.RawTeX(r"\textbf{x}")) == r"\textbf{x}"


def test_fmt_filters_are_latex_safe() -> None:
    assert render.fmt_int(1234567) == r"1\,234\,567"
    assert render.fmt_int(None) == "n/a"
    assert render.fmt_pct(0.1234) == r"12.3\%"
    assert render.fmt_pct(None) == "n/a"
    assert render.fmt_dur(45) == "45s"
    assert render.fmt_dur(3725) == "1h 02m"
    assert render.fmt_ts("2026-10-21T02:05:00+05:30") == "2026-10-21 02:05:00+05:30"
    assert render.fmt_dur(None) == "n/a"


def test_colour_filters_map_known_and_unknown() -> None:
    assert render.severity_colour("MAJOR") == "bad"
    assert render.severity_colour("CRITICAL") == "crit"
    assert render.severity_colour("nonsense") == "idle"
    assert render.status_colour("SUCCESS") == "ok"
    assert render.status_colour("FAILED") == "bad"
    assert render.state_colour("warn") == "warn"
    assert render.state_colour("nonsense") == "idle"
    assert render.plural(1, "table") == "table"
    assert render.plural(2, "table") == "tables"


def test_ident_breaks_long_names() -> None:
    assert r"\_\allowbreak{}" in render.ident("marts.fact_transactions")
    assert r".\allowbreak{}" in render.ident("marts.fact_transactions")


def test_env_uses_custom_delimiters_and_escapes_output() -> None:
    env = render.make_env(REPORTS_DIR / "template")
    template = env.from_string(
        r"\VAR{value} \BLOCK{for x in items}\VAR{x}\BLOCK{endfor}"
    )
    rendered = template.render(value="a_b", items=["c&d"])
    assert rendered == r"a\_b c\&d"


def test_env_rejects_undefined_variables() -> None:
    env = render.make_env(REPORTS_DIR / "template")
    template = env.from_string(r"\VAR{missing}")
    with pytest.raises(jinja2.UndefinedError):
        template.render()


def test_filters_escape_unless_raw() -> None:
    env = render.make_env(REPORTS_DIR / "template")
    template = env.from_string(r"\VAR{value|fmt_int}")
    assert template.render(value=999) == "999"
