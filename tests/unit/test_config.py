"""config is the only .env reader; PROJECT_ROOT and require() stay predictable."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

from src.utils import config

pytestmark = pytest.mark.unit


def _fresh(monkeypatch: pytest.MonkeyPatch, dotenv_path: str):
    monkeypatch.setattr("dotenv.find_dotenv", lambda usecwd: dotenv_path)
    monkeypatch.setattr("dotenv.load_dotenv", lambda *a, **k: None)
    spec = importlib.util.spec_from_file_location("config_fresh", config.__file__)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_project_root_prefers_env(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("PROJECT_ROOT", str(tmp_path))

    module = _fresh(monkeypatch, str(tmp_path / ".env"))

    assert module.PROJECT_ROOT == tmp_path.resolve()


def test_project_root_falls_back_to_dotenv_parent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("PROJECT_ROOT", raising=False)
    env_file = tmp_path / ".env"
    env_file.write_text("", encoding="utf-8")

    module = _fresh(monkeypatch, str(env_file))

    assert module.PROJECT_ROOT == tmp_path.resolve()


def test_project_root_falls_back_to_cwd(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("PROJECT_ROOT", raising=False)
    monkeypatch.chdir(tmp_path)

    module = _fresh(monkeypatch, "")

    assert module.PROJECT_ROOT == tmp_path.resolve()


def test_require_returns_the_value(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SOME_SETTING", "value")

    assert config.require("SOME_SETTING") == "value"


def test_require_rejects_missing_or_blank(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("SOME_SETTING", raising=False)
    with pytest.raises(RuntimeError, match="SOME_SETTING"):
        config.require("SOME_SETTING")

    monkeypatch.setenv("SOME_SETTING", "")
    with pytest.raises(RuntimeError, match="SOME_SETTING"):
        config.require("SOME_SETTING")
