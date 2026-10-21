"""The bundled fonts ship with their licence and the report uses them."""

from __future__ import annotations

import pytest

from reports.scripts.paths import REPORTS_DIR

pytestmark = pytest.mark.unit

FONTS_DIR = REPORTS_DIR / "fonts"

_FACES = (
    "Inter-Regular.ttf",
    "Inter-Italic.ttf",
    "Inter-SemiBold.ttf",
    "Inter-SemiBoldItalic.ttf",
    "JetBrainsMono-Regular.ttf",
    "JetBrainsMono-Bold.ttf",
)
_LICENCES = ("Inter-OFL.txt", "JetBrainsMono-OFL.txt")
_TTF_MAGIC = (b"\x00\x01\x00\x00", b"true", b"OTTO")


@pytest.mark.parametrize("name", _FACES)
def test_the_font_face_is_bundled(name: str) -> None:
    path = FONTS_DIR / name
    assert path.is_file(), f"{name} is missing from reports/fonts"
    assert path.read_bytes()[:4] in _TTF_MAGIC, f"{name} is not a TrueType font"


@pytest.mark.parametrize("name", _LICENCES)
def test_the_family_ships_its_licence(name: str) -> None:
    path = FONTS_DIR / name
    assert path.is_file(), f"{name} is missing from reports/fonts"
    assert "SIL OPEN FONT LICENSE" in path.read_text(encoding="utf-8")


def test_the_style_uses_the_bundled_fonts_with_a_fallback() -> None:
    style = (REPORTS_DIR / "template" / "bankingreport.sty").read_text(encoding="utf-8")
    assert r"\IfFileExists{fonts/Inter-Regular.ttf}" in style
    assert r"\IfFileExists{fonts/JetBrainsMono-Regular.ttf}" in style
    assert "TeX Gyre Heros" in style
    assert "TeX Gyre Cursor" in style


def test_the_latex_build_runs_xelatex() -> None:
    rc = (REPORTS_DIR / "latexmkrc").read_text(encoding="utf-8")
    assert "$pdf_mode = 5;" in rc
    assert "$xelatex" in rc


def test_the_charts_register_the_bundled_fonts() -> None:
    from matplotlib import font_manager

    from reports.scripts import charts

    charts.apply_style(FONTS_DIR)
    families = {font.name for font in font_manager.fontManager.ttflist}
    assert "Inter" in families
    assert "JetBrains Mono" in families
