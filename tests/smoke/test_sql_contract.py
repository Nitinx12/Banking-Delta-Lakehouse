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
        proc = re.search(r"PROCEDURE\s+(audit\.dq_\w+)\s*\(", text, re.IGNORECASE)
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


@pytest.mark.parametrize("layer", ["raw", "staging"])
def test_metadata_freshness_handles_quiet_incremental_tables(layer: str) -> None:
    """Incremental tables can be skipped; freshness must key off the last run.

    A raw/staging table loaded incrementally only writes rows when the source
    changes, so its data timestamp ages while the pipeline is healthy. The
    metadata check must therefore fall back to the last table run for those
    tables instead of failing on a stale data timestamp.
    """
    text = (
        ROOT / "tests" / "data-quality" / layer / "01_lp_check_metadata_col.sql"
    ).read_text(encoding="utf-8")

    assert "audit.source_tables" in text, f"{layer}: must read load_strategy"
    assert "audit.table_runs" in text, f"{layer}: must read the last table run"
    assert "load_strategy" in text, f"{layer}: must branch on load_strategy"
    assert "v_schema || '.' || v_tbl.relname" in text, (
        f"{layer}: table_runs.target_table is schema-qualified"
    )


TIME_DERIVED_BANDS = [
    ("01_dim_customer.sql", "age_band"),
    ("02_dim_account.sql", "account_age_band"),
    ("03_dim_branch.sql", "branch_age_band"),
    ("04_dim_employee.sql", "tenure_band"),
]


@pytest.mark.parametrize("script,band", TIME_DERIVED_BANDS)
def test_time_derived_bands_recheck_drift(script: str, band: str) -> None:
    """Bands computed from AGE(CURRENT_DATE, ...) drift while the source is quiet.

    A birthday or account anniversary crosses a band boundary without any
    staging row changing, so the incremental load must re-pick rows whose
    stored band no longer matches today's recomputation — otherwise the
    derived-attribute DQ gate fails the next run.
    """
    text = (ROOT / "sql" / "analytics" / script).read_text(encoding="utf-8")

    assert f"{band} IS DISTINCT FROM cur.{band}" in text, (
        f"{script}: must re-pick rows whose {band} drifted with time"
    )


def test_employee_tenure_band_boundaries_match_dq_gate() -> None:
    """`< 10` must map to '5-10 yrs'; '10+ yrs' belongs to ELSE only.

    Guards the 2026-10 regression where the load labelled every employee with
    under 10 years tenure as '10+ yrs' while the DQ gate expected '5-10 yrs'.
    """
    text = (ROOT / "sql" / "analytics" / "04_dim_employee.sql").read_text(
        encoding="utf-8"
    )

    assert "< 10 THEN '5-10 yrs'" in text, (
        "04_dim_employee.sql: the < 10 boundary must read '5-10 yrs'"
    )
    assert text.count("< 10 THEN '10+ yrs'") == 0
