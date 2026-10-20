"""SQL layout and data-quality suite contracts.

Guards the conventions the runners rely on: numbered procedure files under a
master load, one layer-scoped dq procedure per suite file, audit rows committed
before the failure is raised.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.smoke

ROOT = Path(__file__).resolve().parents[2]
DQ_LAYERS = ["raw", "staging", "analytics", "marts"]
LOAD_LAYERS = ["staging", "analytics", "marts"]


def _numbered(names: list[str]) -> list[str]:
    """Numeric prefixes excluding master (00) and debug (99) files."""
    return [
        n[:2] for n in names if re.match(r"^\d\d_", n) and n[:2] not in ("00", "99")
    ]


@pytest.mark.parametrize("layer", LOAD_LAYERS)
def test_layer_has_master_load_and_unique_numbering(layer: str) -> None:
    directory = ROOT / "sql" / layer
    assert (directory / "00_master_load.sql").is_file()
    prefixes = _numbered([p.name for p in directory.glob("*.sql")])
    assert len(prefixes) == len(set(prefixes)), f"duplicate numbering in sql/{layer}"


@pytest.mark.parametrize("layer", DQ_LAYERS)
def test_dq_suite_files_follow_contract(layer: str) -> None:
    directory = ROOT / "tests" / "data-quality" / layer
    master = directory / f"00_master_{layer}_tests.sql"
    assert master.is_file(), f"missing {master.name}"
    master_text = master.read_text(encoding="utf-8")

    suite_files = sorted(
        p for p in directory.glob("[0-9][0-9]_*.sql") if not p.name.startswith("00_")
    )
    assert suite_files, f"no DQ suites in {layer}"

    prefixes = _numbered([p.name for p in suite_files])
    assert len(prefixes) == len(set(prefixes)), f"duplicate numbering in {layer}"

    for sql_file in suite_files:
        text = sql_file.read_text(encoding="utf-8")
        proc = re.search(r"PROCEDURE\s+(audit\.dq_\w+)\s*\(", text, re.I)
        assert proc, f"{sql_file.name}: no audit.dq_* procedure"
        assert proc.group(1) in master_text, (
            f"{sql_file.name}: {proc.group(1)} not called by master"
        )
        assert "audit.dq_run" in text, f"{sql_file.name}: no audit.dq_run write"
        assert "audit.dq_violation" in text, (
            f"{sql_file.name}: no audit.dq_violation write"
        )

        code = "\n".join(
            line for line in text.splitlines() if not line.strip().startswith("--")
        )
        upper = code.upper()
        if "RAISE" in upper:
            commit_at, raise_at = upper.find("COMMIT"), upper.rfind("RAISE")
            assert commit_at != -1 and commit_at < raise_at, (
                f"{sql_file.name}: audit rows must be COMMITted before RAISE"
            )
