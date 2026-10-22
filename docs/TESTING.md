# Testing — Banking-Delta-Lakehouse

Two kinds of tests live here:

1. **SQL data-quality suites** (`tests/data-quality/`) — test *the data* against a
   populated warehouse. See `docs/DATA-QUALITY.md`.
2. **Python tests** (`tests/`, `airflow/tests/`) — test *the code*, hermetically.
   This document.

Rules: never weaken a test to get green (`AGENTS.md`).

## Test tiers

| Tier | Marker | Make target | Needs | Agent may run |
|---|---|---|---|---|
| Lint / format | — | `lint`, `format` | ruff | yes |
| SQL lint | — | `sql-lint` | sqlfluff | yes |
| **Unit** | `unit` | `unit`, `cov` | nothing external | yes |
| **Smoke** | `smoke` | `smoke`, `test` | nothing external | yes |
| Spark smoke | `spark` | `spark-smoke` | Java 8/11/17/21 | ask first |
| SQL smoke | — | `sql-smoke` | disposable PG + `ALLOW_SQL_SMOKE=1` | ask first |
| Integration | `integration` | `integration` | disposable PG + `ALLOW_SQL_SMOKE=1` | ask first |
| Live smoke | `live` | `smoke-live` | real configured env (read-only) | ask first |
| DQ gate (data) | — | `dq-*`, `dq` | populated warehouse | ask first |
| Report TeX | `tex` | `report-tex`, `report-pdf`, `report-docker` | TeX Live or Docker | yes |
| Report TeX CI | `tex` | `report-tex` | Docker image (no host TeX) | CI only |
| Gate | — | `ci` = lint + sql-lint + unit + smoke + report-fixture | — | yes |

**Unit test:** one function/class in isolation; collaborators faked; deterministic; no I/O
except `tmp_path`.
**Smoke test:** fast "is it wired up?" checks — every module imports, every CLI answers
`--help`/`--list`, repo/SQL/env contracts hold. Not logic tests.
**Integration test:** real disposable PostgreSQL, real stored procedures, synthetic rows.

Markers are registered in `pyproject.toml` (`[tool.pytest.ini_options] markers`); unmarked
tests are **not selected** by `make unit` / `make smoke` and silently never run. Mark every
test (`@pytest.mark.unit`) or set `pytestmark = pytest.mark.unit` at module top.

## Layout

```text
tests/
├── conftest.py            # fake_env (deterministic config), no_network (autouse)
├── smoke/                 # marker: smoke
│   ├── test_imports.py    # every src/scripts/dashboard-lib module imports
│   ├── test_cli_contracts.py   # main.py --list, run_jobs --help, ...
│   ├── test_repo_contract.py   # required files, markers, hermetic ci, untracked .env
│   ├── test_sql_contract.py    # master loads, unique numbering, DQ suite contract
│   └── test_env_contract.py    # every require()d var is in .env.example
├── unit/                  # (to grow — see "What still needs tests")
├── integration/           # disposable PG only
└── data-quality/          # SQL DQ suites — do not move (docs/DATA-QUALITY.md)
airflow/tests/             # Airflow wiring: DAG integrity, commands, summary, redaction
```

`testpaths = ["tests", "airflow/tests"]`. Mirror the source path in test names
(`src/utils/audit.py` → `tests/unit/utils/test_audit.py`); files `test_<module>.py`, tests
`test_<behaviour>_<condition>_<expected>`.

## Conventions

1. **Arrange / Act / Assert**, one behaviour per test; `pytest.mark.parametrize` for case
   tables.
2. **Hermetic by default** — `tests/conftest.py` blocks `socket.socket.connect` for
   `unit`/`smoke` tests. Fake drivers (`pymysql`, `pymongo`, `psycopg2`,
   `databricks.sql`) with `monkeypatch`; never import real connections at module scope.
3. **Config via `fake_env` / `monkeypatch.setenv`**, never by editing `.env`
   (`src/utils/config.py` is the only reader and uses `override=False`).
4. **Filesystem via `tmp_path`**; no writes to `.spark/`, `logs/` or the repo root.
5. **Time:** timezone-aware UTC only (`datetime.now(timezone.utc)`); inject or freeze time;
   no `sleep`.
6. **Money:** `Decimal("123.45")` / `NUMERIC(18,2)`; never `float`.
7. **No row values or secrets** in assertions or logs — counts, names, statuses only.
8. **Windows-safe:** `pathlib`, `sys.executable`, `encoding="utf-8"` on every
   `open`/`read_text`, no `fcntl`/`signal.setitimer` (see `airflow/tests/conftest.py`
   stubs). The repo has been bitten by cp1252 consoles.
9. **Fast:** one unit test < 100 ms; unit tier < 1 min; smoke tier < 1 min.
10. **Deterministic and order-independent.**

## Inner loop

```bash
uv run pytest tests/smoke/test_imports.py -q    # one file
uv run pytest -m unit -k redact -x              # keyword, stop on first failure
pwsh scripts/run_tests.ps1                      # every test file + all 4 DQ suites, report at the end
make format                                      # auto-fix style
make ci                                          # lint + sql-lint + unit + smoke
```

`scripts/run_tests.ps1` runs each pytest file on its own, then the raw/staging/analytics/marts
DQ runners, and prints a per-file report with totals (saved to `logs/test-report-<stamp>.txt`,
exit 1 on any failure). `-SkipDq` drops the DQ suites, `-Filter <text>` picks files, `-Marker all`
runs every marker (`spark`, `tex`, ...) instead of the default `unit or smoke`.

Restricted (ask first): `make spark-smoke`, `ALLOW_SQL_SMOKE=1 make sql-smoke integration`
(disposable PG only), `make smoke-live`.

## Definition of done

- `make ci` green locally; `make cov` if covered code changed (never lower `fail_under`).
- New behaviour has a test; a fix ships with a regression test that failed before it.
- Extra tiers the change requires were run, or listed as "not run, needs approval".
- Every new test has a marker and actually runs under `make unit` / `make smoke`.

## Regression tests this repo needs (known gotchas)

| Test | Guards against |
|---|---|
| `spark_io._dbx_where` uses strict `>` on the lower bound | boundary row re-landed every run |
| `engine._clean_packages` drops `#` comments, resolves Maven coordinates | comment text reaching Maven |
| `main.py` forces UTF-8 before building the Rich console | cp1252 crash on Windows |
| `main.py` step order = the 9 gated steps; `--only` accepts each name | Airflow task ↔ step name drift |
| `run_jobs.py` order `mongo → databricks → mysql`; exit 0 only if all sources 0 | extract ordering / silent failure |
| `finish_pipeline_run` rolls up using the latest attempt per table only | wrong SUCCESS/PARTIAL/FAILED |
| `summary.decide_status` never returns SUCCESS when a step state is missing | false-green mail |
| `redact` strips URL creds, `password=`/`token=`, PEM blocks; ≤ 300 chars | secret leak in mail/audit |
| `MART_CONFIG` has keys + watermark column + kind for all 7 marts | publish misconfiguration |
| DAG: `max_active_runs=1`, DQ gates `retries=0`, `trigger_rule=all_done` on finalize/summary | orchestration regressions |
| watermark code never mixes `extract_watermarks` and `etl_watermarks` | cross-layer corruption |
| `reports.scripts.tex_escape` covers all 10 LaTeX specials + `None` + unicode | broken compiles from error text |
| `reports.scripts.tex_escape` neutralises `\input{...}`, `\write18`, `\immediate` in free text | LaTeX injection through audit messages |
| `reports.scripts.RenderTeX` is the only escape bypass; `StrictUndefined` raises on missing key | silent blanks, accidental raw output |
| severity rules R001–R017: one table-driven test per rule | wrong or downgraded severity |
| verdict is maximum severity; `UNKNOWN` never renders as `ok` | false green report |
| latest attempt per table decides the table status | a retry that succeeded reported as failed |
| redaction applied to every free text field, 300 char cap | secrets in mail or PDF |
| `context.json` validates against schema for every fixture | contract drift |
| chapter selection per kind and `drop_when_empty` | wrong chapters appearing |
| deterministic render: same context gives byte-identical `.tex` | flaky diffs |
| palette in `charts.py` equals colours in `bankingreport.sty` | design drift |
| chart functions return a figure for empty data | build failure on quiet days |
| `build --fixture X --no-pdf` leaves no `\VAR{` or `\BLOCK{` in `build/` | unrendered template text |
| `tex` tier: every fixture compiles, log has no `!` errors, pages within budget | broken LaTeX |
| `tex` tier: safe mode compiles when figures directory is empty | degraded path rot |
| mail: attachment added, oversize skipped, missing file still sends | lost summary mail |
| DAG integrity for `build_report` and `banking_report_weekly` | orchestration regressions |
| read-only guard: collector issues only `SELECT` statements | accidental writes |

## Known status (2026-10-20)

- `make lint`, `make contracts`, `make sql-lint`, `make unit`, `make smoke`,
  `make cov` and `make ci` are green. `tasks.bat ci` mirrors them on Windows.
- `make sql-lint` uses an explicit `.sqlfluff` baseline (dialect `postgres`,
  keyword/identifier/type case pinned, and the merged SQL's layout/aliasing/ambiguity
  rules excluded with reasons). `sql/raw/*.sql` exploration probes are ignored via
  `.sqlfluffignore` because they use a bare `OFFSET 0` Spark hint the parser rejects.
  Pipeline SQL under `sql/{staging,analytics,marts}` and `sql/scripts` is linted.
- `make sql-smoke`, `make integration` and `make spark-smoke` need a disposable
  Postgres / local Spark and are out of the PR gate.
