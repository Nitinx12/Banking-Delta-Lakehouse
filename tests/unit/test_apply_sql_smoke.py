"""apply_sql_smoke: the shared sql-smoke file list, its guard, and its psql call."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from scripts import apply_sql_smoke

pytestmark = pytest.mark.unit

_DIRS = (
    "sql/scripts",
    "sql/functions",
    "sql/staging",
    "sql/analytics",
    "sql/marts",
    "tests/data-quality/raw",
    "tests/data-quality/staging",
    "tests/data-quality/analytics",
    "tests/data-quality/marts",
)


def _fake_repo(root: Path) -> list[str]:
    """One keep file per group plus every excluded name; return the keep list."""
    expected: list[str] = []
    for directory in _DIRS:
        folder = root / directory
        folder.mkdir(parents=True)
        keep = folder / "01_keep.sql"
        keep.write_text("SELECT 1;", encoding="utf-8")
        expected.append(keep.relative_to(root).as_posix())
    boundary = root / "sql" / "scripts" / "06_switch_mysql_incremental.sql"
    boundary.write_text("SELECT 1;", encoding="utf-8")
    expected.insert(1, boundary.relative_to(root).as_posix())
    excluded = (
        "sql/scripts/00_create_database.sql",
        "sql/scripts/05_switch.sql",
        "sql/staging/00_master_load.sql",
        "sql/staging/99_debug_staging.sql",
        "sql/analytics/00_master_load.sql",
        "sql/analytics/99_debug_analytics.sql",
        "sql/marts/00_master_load.sql",
        "tests/data-quality/raw/00_master_raw.sql",
        "tests/data-quality/staging/00_master_staging.sql",
        "tests/data-quality/analytics/00_master_analytics.sql",
        "tests/data-quality/marts/00_master_marts.sql",
    )
    for relative in excluded:
        path = root / relative
        path.write_text("SELECT 1;", encoding="utf-8")
    return expected


def test_file_list_matches_the_make_loop(tmp_path: Path) -> None:
    expected = _fake_repo(tmp_path)
    found = [
        path.relative_to(tmp_path).as_posix()
        for path in apply_sql_smoke.sql_files(tmp_path)
    ]
    assert found == expected


def test_missing_group_directory_fails_loudly(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError, match="missing SQL directory"):
        apply_sql_smoke.sql_files(tmp_path)


def test_refuses_without_the_flag(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.delenv("ALLOW_SQL_SMOKE", raising=False)
    assert apply_sql_smoke.main([]) == 1
    assert "Refusing" in capsys.readouterr().out


def test_refuses_when_the_flag_is_not_one(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALLOW_SQL_SMOKE", "0")
    assert apply_sql_smoke.main([]) == 1


def test_psql_command_targets_the_configured_database(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("PG_HOST", "db.example")
    monkeypatch.setenv("PG_PORT", "6543")
    monkeypatch.setenv("PG_DB", "warehouse")
    monkeypatch.setenv("PG_USER", "loader")
    path = tmp_path / "01_keep.sql"
    assert apply_sql_smoke.psql_command(path) == [
        "psql",
        "-v",
        "ON_ERROR_STOP=1",
        "-X",
        "-q",
        "-h",
        "db.example",
        "-p",
        "6543",
        "-d",
        "warehouse",
        "-U",
        "loader",
        "-f",
        str(path),
    ]


def test_psql_env_falls_back_to_the_project_password(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("PGPASSWORD", raising=False)
    monkeypatch.setenv("PG_PASS", "s3cret")
    assert apply_sql_smoke.psql_env()["PGPASSWORD"] == "s3cret"


def test_psql_env_keeps_an_explicit_libpq_password(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PG_PASS", "s3cret")
    monkeypatch.setenv("PGPASSWORD", "already")
    assert apply_sql_smoke.psql_env()["PGPASSWORD"] == "already"


def test_main_applies_every_file_in_order(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    expected = _fake_repo(tmp_path)
    monkeypatch.setattr(apply_sql_smoke, "REPO_ROOT", tmp_path)
    monkeypatch.setenv("ALLOW_SQL_SMOKE", "1")
    applied: list[str] = []

    def _record(
        cmd: list[str], env: dict[str, str] | None = None, check: bool = False
    ) -> subprocess.CompletedProcess:
        target = Path(cmd[cmd.index("-f") + 1])
        applied.append(target.relative_to(tmp_path).as_posix())
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(apply_sql_smoke.subprocess, "run", _record)
    assert apply_sql_smoke.main([]) == 0
    assert applied == expected


def test_main_stops_at_the_first_failing_file(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _fake_repo(tmp_path)
    monkeypatch.setattr(apply_sql_smoke, "REPO_ROOT", tmp_path)
    monkeypatch.setenv("ALLOW_SQL_SMOKE", "1")
    calls: list[str] = []

    def _fail_on_second(
        cmd: list[str], env: dict[str, str] | None = None, check: bool = False
    ) -> subprocess.CompletedProcess:
        calls.append(Path(cmd[cmd.index("-f") + 1]).name)
        return subprocess.CompletedProcess(cmd, 1 if len(calls) == 2 else 0)

    monkeypatch.setattr(apply_sql_smoke.subprocess, "run", _fail_on_second)
    assert apply_sql_smoke.main([]) == 1
    assert len(calls) == 2


def test_main_reports_a_missing_psql_binary(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _fake_repo(tmp_path)
    monkeypatch.setattr(apply_sql_smoke, "REPO_ROOT", tmp_path)
    monkeypatch.setenv("ALLOW_SQL_SMOKE", "1")

    def _missing(
        cmd: list[str], env: dict[str, str] | None = None, check: bool = False
    ) -> subprocess.CompletedProcess:
        raise FileNotFoundError("psql")

    monkeypatch.setattr(apply_sql_smoke.subprocess, "run", _missing)
    assert apply_sql_smoke.main([]) == 1
