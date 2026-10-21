"""The build CLI renders every fixture deterministically and keeps exit codes honest."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from reports.scripts import build
from reports.scripts.paths import FIXTURES_DIR

pytestmark = pytest.mark.unit


@pytest.fixture
def sandbox(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr("reports.scripts.paths.BUILD_DIR", tmp_path / "build")
    monkeypatch.setattr("reports.scripts.paths.FIGURES_DIR", tmp_path / "figures")
    monkeypatch.setattr(
        "reports.scripts.paths.context_path", lambda: tmp_path / "context.json"
    )
    monkeypatch.setenv("REPORT_OUTPUT_DIR", str(tmp_path / "output"))
    return tmp_path


def _build_dir() -> Path:
    from reports.scripts import paths

    return paths.BUILD_DIR


def _rendered() -> str:
    return "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(_build_dir().glob("*.tex"))
    )


def test_all_fixtures_render_without_a_pdf(sandbox: Path) -> None:
    code = build.main(["--all-fixtures", "--no-pdf"])
    assert code == build.EXIT_OK
    assert _rendered()
    assert "\\VAR{" not in _rendered()
    assert "\\BLOCK{" not in _rendered()


def test_unrendered_template_tag_fails_the_build(sandbox: Path) -> None:
    build_dir = sandbox / "build"
    build_dir.mkdir(parents=True)
    (build_dir / "01_summary.tex").write_text(
        "\\section{Summary} \\VAR{verdict.label}", encoding="utf-8"
    )
    with pytest.raises(build.RenderError):
        build._assert_rendered(build_dir)


def test_leftover_tag_in_a_rendered_chapter_exits_two(
    sandbox: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def leaky_render(env, template_vars, chapter_names, build_dir) -> None:
        build_dir.mkdir(parents=True, exist_ok=True)
        (build_dir / "01_summary.tex").write_text(
            "\\section{Summary} \\VAR{verdict.label}", encoding="utf-8"
        )
        build._assert_rendered(build_dir)

    monkeypatch.setattr(build, "_render", leaky_render)
    assert build.main(["--fixture", "healthy", "--no-pdf"]) == build.EXIT_INVALID
    assert "render error" in capsys.readouterr().err


def test_render_checks_every_chapter_for_leftover_tags(
    sandbox: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    checked: list[Path] = []
    original = build._assert_rendered

    def record(build_dir: Path) -> None:
        checked.append(build_dir)
        original(build_dir)

    monkeypatch.setattr(build, "_assert_rendered", record)
    assert build.main(["--fixture", "healthy", "--no-pdf"]) == build.EXIT_OK
    assert checked


def test_daily_fixture_has_every_chapter(sandbox: Path) -> None:
    assert build.main(["--fixture", "healthy", "--no-pdf"]) == 0
    chapters = sorted(path.name for path in _build_dir().glob("*.tex"))
    assert chapters == [
        "01_summary.tex",
        "02_flow.tex",
        "03_timeline.tex",
        "04_volumes.tex",
        "05_dq.tex",
        "06_freshness.tex",
        "07_incidents.tex",
        "09_appendix.tex",
        "manifest.tex",
        "meta.tex",
    ]
    manifest = (_build_dir() / "manifest.tex").read_text(encoding="utf-8")
    for chapter in ("01_summary", "02_flow", "09_appendix"):
        assert f"\\input{{build/{chapter}}}" in manifest
    assert "\\section{Summary}" in (_build_dir() / "01_summary.tex").read_text(
        encoding="utf-8"
    )


def test_output_escapes_identifiers(sandbox: Path) -> None:
    build.main(["--fixture", "healthy", "--no-pdf"])
    rendered = _rendered()
    assert r"dim\_\allowbreak{}customer" in rendered
    assert "dim_customer" not in rendered


def test_weekly_kind_drops_timeline_and_adds_trends(sandbox: Path) -> None:
    build.main(["--fixture", "weekly", "--no-pdf"])
    manifest = (_build_dir() / "manifest.tex").read_text(encoding="utf-8")
    assert "\\input{build/08_trends}" in manifest
    assert "\\input{build/03_timeline}" not in manifest


def test_no_charts_skips_figures(sandbox: Path) -> None:
    build.main(["--fixture", "healthy", "--no-pdf", "--no-charts"])
    assert not (sandbox / "figures").exists()
    assert "includegraphics" not in _rendered()


def test_unknown_fixture_exits_two(sandbox: Path) -> None:
    assert build.main(["--fixture", "nope", "--no-pdf"]) == 2


def test_invalid_context_exits_two(
    sandbox: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bad_dir = sandbox / "fixtures"
    bad_dir.mkdir(parents=True)
    (bad_dir / "bad.json").write_text(
        json.dumps({"schema_version": 1}), encoding="utf-8"
    )
    monkeypatch.setattr("reports.scripts.paths.FIXTURES_DIR", bad_dir)
    assert build.main(["--fixture", "bad", "--no-pdf"]) == 2


def test_strict_fails_on_degraded_sections(sandbox: Path) -> None:
    code = build.main(["--fixture", "critical_failed_run", "--no-pdf", "--strict"])
    assert code == build.EXIT_INVALID


def test_context_json_carries_the_verdict(sandbox: Path) -> None:
    build.main(["--fixture", "critical_failed_run", "--no-pdf"])
    context = json.loads((sandbox / "context.json").read_text(encoding="utf-8"))
    assert context["verdict"]["severity"] == "CRITICAL"
    assert {event["rule"] for event in context["events"]} >= {"R001", "R005"}


def test_out_flag_wins_over_the_environment(
    sandbox: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REPORT_OUTPUT_DIR", str(sandbox / "elsewhere"))
    build.main(["--fixture", "healthy", "--no-pdf", "--out", str(sandbox / "chosen")])
    assert (sandbox / "chosen").is_dir()


def test_environment_root_is_used_without_out(
    sandbox: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REPORT_OUTPUT_DIR", str(sandbox / "elsewhere"))
    build.main(["--fixture", "healthy", "--no-pdf"])
    assert (sandbox / "elsewhere").is_dir()


def test_fixture_path_accepts_a_name_or_a_path(sandbox: Path) -> None:
    assert build.main(["--fixture", "healthy", "--no-pdf"]) == 0
    assert (
        build.main(["--fixture", str(FIXTURES_DIR / "healthy.json"), "--no-pdf"]) == 0
    )


def test_json_result_has_the_documented_keys(
    sandbox: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    build.main(["--fixture", "healthy", "--no-pdf"])
    payload = json.loads(capsys.readouterr().out.strip())
    assert set(payload) == {"kind", "verdict", "pages", "path", "degraded"}
    assert payload["kind"] == "daily"
    assert payload["verdict"] == "INFO"


def test_compile_failure_in_safe_mode_exits_three(
    sandbox: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(build.compile_mod, "compile_pdf", lambda *_a, **_k: False)
    assert build.main(["--fixture", "healthy"]) == build.EXIT_COMPILE_FAILED
    payload = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert payload["degraded"] is True
    assert payload["pages"] is None
    assert payload["path"] is None


def test_safe_mode_retry_drops_the_figures(
    sandbox: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    calls: list[str] = []

    def fake_compile(
        _workdir: Path,
        *,
        jobname: str = "report",
        log_path: Path | None = None,
        timeout: int = 600,
        epoch: str | None = None,
    ) -> bool:
        calls.append(jobname)
        if len(calls) == 1:
            return False
        (build.paths.BUILD_DIR / f"{jobname}.pdf").write_bytes(b"%PDF-1.4")
        return True

    monkeypatch.setattr(build.compile_mod, "compile_pdf", fake_compile)
    assert build.main(["--fixture", "healthy"]) == build.EXIT_OK
    payload = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert payload["degraded"] is True
    assert payload["path"] is not None
    assert "includegraphics" not in _rendered()


def test_daily_build_also_builds_the_incident_pdf(
    sandbox: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def fake_compile(
        _workdir: Path,
        *,
        jobname: str = "report",
        log_path: Path | None = None,
        timeout: int = 600,
        epoch: str | None = None,
    ) -> bool:
        (build.paths.BUILD_DIR / f"{jobname}.pdf").write_bytes(b"%PDF-1.4")
        return True

    monkeypatch.setattr(build.compile_mod, "compile_pdf", fake_compile)
    assert build.main(["--fixture", "critical_failed_run"]) == build.EXIT_OK
    output = sandbox / "output"
    assert (output / "runs" / "fixture__critical_failed_run" / "report.pdf").is_file()
    assert (output / "runs" / "fixture__critical_failed_run" / "incident.pdf").is_file()
    assert (output / "report.pdf").is_file()
    assert (output / "incident.pdf").is_file()
