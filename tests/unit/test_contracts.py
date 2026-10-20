"""Contract files must stay valid and consistent with the source registry."""

import copy
import json

import pytest

from contracts.validate import CONTRACTS_DIR, all_contract_paths, validate_contract

pytestmark = pytest.mark.unit

_PATHS = all_contract_paths()
_TEMPLATES = {"example_table.json"}
_REGISTRY_FIELDS = (
    "source",
    "business_key",
    "load_strategy",
    "incremental_column",
    "watermark_strategy",
)


def _load(path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def test_contracts_are_discovered():
    assert _PATHS, "no contracts found under contracts/"


@pytest.mark.parametrize("path", _PATHS, ids=lambda p: p.name)
def test_each_contract_is_valid(path):
    validate_contract(_load(path), path=str(path))


@pytest.mark.parametrize("path", _PATHS, ids=lambda p: p.name)
def test_contract_name_matches_filename(path):
    assert _load(path)["target_table"] == path.stem


def test_contract_names_are_unique():
    names = [_load(p)["name"] for p in _PATHS]
    assert len(names) == len(set(names))


def test_money_columns_are_numeric():
    for path in _PATHS:
        for column in _load(path)["columns"]:
            if any(word in column["name"] for word in ("amount", "balance", "income")):
                assert column["type"] == "numeric(18,2)", (
                    f"{path.name}:{column['name']}"
                )


def test_landing_audit_columns_are_not_declared():
    for path in _PATHS:
        names = {c["name"] for c in _load(path)["columns"]}
        assert "_batch_id" not in names and "_loaded_at" not in names


def test_registry_agrees_with_contracts():
    registry = json.loads((CONTRACTS_DIR / "registry.json").read_text(encoding="utf-8"))
    by_table = {entry["target_table"]: entry for entry in registry["tables"]}
    for path in _PATHS:
        if path.name in _TEMPLATES:
            continue
        contract = _load(path)
        entry = by_table.get(contract["target_table"])
        assert entry is not None, f"{path.name}: not in registry.json"
        for field in _REGISTRY_FIELDS:
            assert entry[field] == contract.get(field), (
                f"{path.name}: {field} drifted from registry"
            )


def test_validator_rejects_broken_variants():
    base = _load(next(p for p in _PATHS if p.name == "accounts.json"))

    missing = copy.deepcopy(base)
    del missing["quality"]
    with pytest.raises(ValueError):
        validate_contract(missing)

    bad_key = copy.deepcopy(base)
    bad_key["business_key"] = ["not_a_column"]
    with pytest.raises(ValueError):
        validate_contract(bad_key)

    bad_type = copy.deepcopy(base)
    bad_type["columns"][1]["type"] = "float"
    with pytest.raises(ValueError):
        validate_contract(bad_type)

    full_with_column = copy.deepcopy(base)
    full_with_column["incremental_column"] = "created_at"
    with pytest.raises(ValueError):
        validate_contract(full_with_column)

    bad_contract_version = copy.deepcopy(base)
    bad_contract_version["contract_version"] = 2
    with pytest.raises(ValueError):
        validate_contract(bad_contract_version)
