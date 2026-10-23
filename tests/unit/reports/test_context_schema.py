"""Every fixture must satisfy context.schema.json, the versioned context contract."""

from __future__ import annotations

import copy
import json
import re
from pathlib import Path
from typing import Any

import jsonschema
import pytest
import yaml

from reports.scripts import paths

pytestmark = pytest.mark.unit

_SCHEMA = json.loads(paths.CONTEXT_SCHEMA.read_text(encoding="utf-8"))
_VALIDATOR = jsonschema.Draft202012Validator(_SCHEMA)
_CONFIG = yaml.safe_load(
    (paths.REPORTS_DIR / "config" / "report.yaml").read_text(encoding="utf-8")
)
_FIXTURES = paths.fixture_paths()
_IDS = [path.stem for path in _FIXTURES]


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def test_schema_declares_version_two() -> None:
    assert _SCHEMA["properties"]["schema_version"] == {"const": 2}


@pytest.mark.parametrize("path", _FIXTURES, ids=_IDS)
def test_fixture_validates_against_schema(path: Path) -> None:
    _VALIDATOR.validate(_load(path))


@pytest.mark.parametrize("path", _FIXTURES, ids=_IDS)
def test_fixture_kind_exists_in_report_config(path: Path) -> None:
    assert _load(path)["meta"]["kind"] in _CONFIG["kinds"]


def test_schema_rejects_unknown_verdict_severity() -> None:
    broken = copy.deepcopy(_load(paths.FIXTURES_DIR / "healthy.json"))
    broken["verdict"]["severity"] = "OK"
    with pytest.raises(jsonschema.ValidationError):
        _VALIDATOR.validate(broken)


def test_schema_rejects_error_message_over_the_cap() -> None:
    broken = copy.deepcopy(_load(paths.FIXTURES_DIR / "major_dq_fail.json"))
    broken["errors"][0]["message"] = "x" * 301
    with pytest.raises(jsonschema.ValidationError):
        _VALIDATOR.validate(broken)


def test_schema_rejects_event_rule_outside_the_catalogue() -> None:
    broken = copy.deepcopy(_load(paths.FIXTURES_DIR / "minor_retry.json"))
    broken["events"][0]["rule"] = "RULE-7"
    with pytest.raises(jsonschema.ValidationError):
        _VALIDATOR.validate(broken)


def test_every_fixture_event_uses_a_catalogue_rule_id() -> None:
    for path in _FIXTURES:
        for event in _load(path)["events"]:
            assert re.fullmatch(r"R\d{3}", event["rule"]), event["event_id"]
