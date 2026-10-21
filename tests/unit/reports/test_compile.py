"""latexmk never raises; a missing binary or a failed run reports False."""

from __future__ import annotations

import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from reports.scripts import compile as compile_mod

pytestmark = pytest.mark.unit


def test_latexmk_available_reflects_the_path(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(compile_mod.shutil, "which", lambda _name: None)
    assert compile_mod.latexmk_available() is False
    monkeypatch.setattr(compile_mod.shutil, "which", lambda _name: "/usr/bin/latexmk")
    assert compile_mod.latexmk_available() is True


def test_compile_pdf_returns_false_when_latexmk_is_missing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(compile_mod.shutil, "which", lambda _name: None)
    assert compile_mod.compile_pdf(tmp_path) is False


def test_compile_pdf_passes_the_safety_flags(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    seen: dict[str, object] = {}

    class Result:
        returncode = 0
        stdout = "ok"
        stderr = ""

    def fake_run(command: list[str], **kwargs: object) -> Result:
        seen["command"] = command
        seen.update(kwargs)
        return Result()

    monkeypatch.setattr(compile_mod.subprocess, "run", fake_run)
    assert compile_mod.compile_pdf(tmp_path, log_path=tmp_path / "log.txt") is True
    command = seen["command"]
    assert command[0] == "latexmk"
    assert "-r" in command
    assert "main.tex" in command
    assert seen["timeout"] == compile_mod.LATEXMK_TIMEOUT_S
    assert (tmp_path / "log.txt").read_text(encoding="utf-8") == "ok\n"


def test_compile_pdf_names_the_job_after_the_kind(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    seen: dict[str, object] = {}

    class Result:
        returncode = 0
        stdout = "ok"
        stderr = ""

    def fake_run(command: list[str], **kwargs: object) -> Result:
        seen["command"] = command
        return Result()

    monkeypatch.setattr(compile_mod.subprocess, "run", fake_run)
    compile_mod.compile_pdf(tmp_path, jobname="incident")
    assert "-jobname=incident" in seen["command"]


def test_compile_log_is_redacted(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    class Result:
        returncode = 1
        stdout = "login failed password=hunter2"
        stderr = ""

    monkeypatch.setattr(compile_mod.subprocess, "run", lambda *_a, **_k: Result())
    log = tmp_path / "report.log"
    compile_mod.compile_pdf(tmp_path, log_path=log)
    assert "hunter2" not in log.read_text(encoding="utf-8")
    assert "password=***" in log.read_text(encoding="utf-8")


def test_page_count_reads_the_compile_log(tmp_path: Path) -> None:
    log = tmp_path / "report.log"
    log.write_text(
        "Output written on report.pdf (6 pages, 123456 bytes).\n", encoding="utf-8"
    )
    assert compile_mod.page_count(log) == 6
    assert compile_mod.page_count(tmp_path / "missing.log") is None


def test_page_count_takes_the_last_pass(tmp_path: Path) -> None:
    log = tmp_path / "report.log"
    log.write_text(
        "Output written on report.pdf (1 pages, 10 bytes).\n"
        "Output written on report.pdf (6 pages, 123456 bytes).\n",
        encoding="utf-8",
    )
    assert compile_mod.page_count(log) == 6


def test_latexmk_dirs_follow_the_latexmkrc(tmp_path: Path) -> None:
    out_dir, aux_dir = compile_mod.latexmk_dirs(tmp_path)
    assert out_dir == tmp_path / "build"
    assert aux_dir == tmp_path / "build" / "aux"


def test_clean_job_state_removes_the_stale_latex_files(tmp_path: Path) -> None:
    out_dir = tmp_path / "build"
    aux_dir = out_dir / "aux"
    aux_dir.mkdir(parents=True)
    for name in ("report.aux", "report.fdb_latexmk", "report.fls", "report.pdf"):
        (aux_dir / name).write_text("x", encoding="utf-8")
    (out_dir / "report.pdf").write_text("x", encoding="utf-8")
    (aux_dir / "incident.aux").write_text("x", encoding="utf-8")

    compile_mod.clean_job_state(out_dir, aux_dir, "report")

    assert not (aux_dir / "report.aux").exists()
    assert not (aux_dir / "report.fdb_latexmk").exists()
    assert not (aux_dir / "report.fls").exists()
    assert not (aux_dir / "report.pdf").exists()
    assert not (out_dir / "report.pdf").exists()
    assert (aux_dir / "incident.aux").exists()


def test_compile_pdf_cleans_the_state_before_it_runs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    aux_dir = tmp_path / "build" / "aux"
    aux_dir.mkdir(parents=True)
    stale = aux_dir / "report.aux"
    stale.write_text("ent }", encoding="utf-8")

    class Result:
        returncode = 0
        stdout = "ok"
        stderr = ""

    monkeypatch.setattr(compile_mod.subprocess, "run", lambda *_a, **_k: Result())
    assert compile_mod.compile_pdf(tmp_path) is True
    assert not stale.exists()


def test_source_date_epoch_follows_the_run_end() -> None:
    expected = datetime(
        2026, 10, 21, 2, 5, tzinfo=timezone(timedelta(hours=5, minutes=30))
    )
    assert compile_mod.source_date_epoch("2026-10-21T02:05:00+05:30") == str(
        int(expected.timestamp())
    )
    assert compile_mod.source_date_epoch(None) == compile_mod.DEFAULT_EPOCH
    assert compile_mod.source_date_epoch("nonsense") == compile_mod.DEFAULT_EPOCH


def test_compile_pdf_returns_false_on_a_nonzero_exit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    class Result:
        returncode = 1
        stdout = ""
        stderr = "! Emergency stop"

    monkeypatch.setattr(compile_mod.subprocess, "run", lambda *_a, **_k: Result())
    assert compile_mod.compile_pdf(tmp_path) is False


def test_compile_pdf_swallows_a_timeout(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def boom(*_a: object, **_k: object) -> None:
        raise subprocess.TimeoutExpired(cmd="latexmk", timeout=1)

    monkeypatch.setattr(compile_mod.subprocess, "run", boom)
    assert compile_mod.compile_pdf(tmp_path, timeout=1) is False
