"""Unit tests for scripts/seed_watermarks.py."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import seed_watermarks  # noqa: E402 - script path is set above


def _cfg(**overrides) -> dict:
    cfg = {
        "source_schema": "bank",
        "source_table": "loans",
        "load_strategy": "incremental",
        "incremental_column": "updated_at",
    }
    cfg.update(overrides)
    return cfg


class TestSeedSource:
    def test_full_load_tables_are_skipped(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            seed_watermarks,
            "get_enabled_tables",
            lambda name: [_cfg(load_strategy="full")],
        )
        called: list = []
        monkeypatch.setitem(
            seed_watermarks.MAX_WATERMARK,
            "mongodb_source",
            lambda cfg: called.append(cfg),
        )

        assert seed_watermarks.seed_source("mongodb_source", force=False, dry_run=False)
        assert called == []

    def test_source_failure_marks_run_failed(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            seed_watermarks, "get_enabled_tables", lambda name: [_cfg()]
        )

        def _boom(cfg):
            raise RuntimeError("mongo down")

        monkeypatch.setitem(seed_watermarks.MAX_WATERMARK, "mongodb_source", _boom)

        assert not seed_watermarks.seed_source(
            "mongodb_source", force=False, dry_run=False
        )

    def test_empty_source_does_not_seed(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(
            seed_watermarks, "get_enabled_tables", lambda name: [_cfg()]
        )
        monkeypatch.setitem(
            seed_watermarks.MAX_WATERMARK, "databricks_source", lambda cfg: None
        )
        seeded: list = []
        monkeypatch.setattr(
            seed_watermarks, "seed_watermark", lambda *a, **k: seeded.append((a, k))
        )

        assert seed_watermarks.seed_source(
            "databricks_source", force=False, dry_run=False
        )
        assert seeded == []

    def test_dry_run_never_writes(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(
            seed_watermarks, "get_enabled_tables", lambda name: [_cfg()]
        )
        monkeypatch.setitem(
            seed_watermarks.MAX_WATERMARK, "databricks_source", lambda cfg: "2024-05-01"
        )
        seeded: list = []
        monkeypatch.setattr(
            seed_watermarks, "seed_watermark", lambda *a, **k: seeded.append((a, k))
        )

        assert seed_watermarks.seed_source(
            "databricks_source", force=True, dry_run=True
        )
        assert seeded == []

    @pytest.mark.parametrize("seed_result", [True, False])
    def test_seed_result_does_not_fail_the_run(
        self, monkeypatch: pytest.MonkeyPatch, seed_result: bool
    ) -> None:
        monkeypatch.setattr(
            seed_watermarks, "get_enabled_tables", lambda name: [_cfg()]
        )
        monkeypatch.setitem(
            seed_watermarks.MAX_WATERMARK, "databricks_source", lambda cfg: "2024-05-01"
        )
        seen: list[dict] = []
        monkeypatch.setattr(
            seed_watermarks,
            "seed_watermark",
            lambda cfg, value, force: seen.append(
                {"cfg": cfg, "value": value, "force": force}
            )
            or seed_result,
        )

        assert seed_watermarks.seed_source(
            "databricks_source", force=True, dry_run=False
        )
        assert seen == [{"cfg": _cfg(), "value": "2024-05-01", "force": True}]


class TestMain:
    def test_defaults_seed_both_sources(self, monkeypatch: pytest.MonkeyPatch) -> None:
        calls: list[tuple[str, bool, bool]] = []
        monkeypatch.setattr(
            seed_watermarks,
            "seed_source",
            lambda name, *, force, dry_run: calls.append((name, force, dry_run))
            or True,
        )

        assert seed_watermarks.main([]) == 0
        assert calls == [
            ("databricks_source", False, False),
            ("mongodb_source", False, False),
        ]

    def test_flags_are_forwarded(self, monkeypatch: pytest.MonkeyPatch) -> None:
        calls: list[tuple[str, bool, bool]] = []
        monkeypatch.setattr(
            seed_watermarks,
            "seed_source",
            lambda name, *, force, dry_run: calls.append((name, force, dry_run))
            or True,
        )

        assert (
            seed_watermarks.main(
                ["--force", "--dry-run", "--sources", "mongodb_source"]
            )
            == 0
        )
        assert calls == [("mongodb_source", True, True)]

    def test_any_failed_source_returns_one(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            seed_watermarks, "seed_source", lambda name, **kw: name == "mongodb_source"
        )

        assert (
            seed_watermarks.main(["--sources", "mongodb_source", "databricks_source"])
            == 1
        )

    def test_rejects_unknown_source(self, monkeypatch: pytest.MonkeyPatch) -> None:
        with pytest.raises(SystemExit):
            seed_watermarks.main(["--sources", "mysql_source"])
