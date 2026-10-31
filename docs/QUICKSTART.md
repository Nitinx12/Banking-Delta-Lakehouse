# Quick start — Banking-Delta-Lakehouse

End-to-end guide to getting the pipeline running on a developer machine. For the
full blueprint read `ARCHITECTURE.md`; for day-to-day operations read
`docs/RUNBOOK.md`. Colour legend: `docs/PIPELINE.md`.

## 0. Prerequisites

- Git, `uv`, GNU Make (Windows: use `tasks.bat`, or install Make via Chocolatey)
- Python 3.13 (pinned in `pyproject.toml` / `.python-version`)
- Java 8/11/17/21 for the Spark extract paths
- PostgreSQL 16 client (`psql`) and a disposable warehouse database
- Docker + Docker Compose for the Airflow stack (optional but recommended)
- A TeX distribution with `latexmk` + `pdflatex` for PDF reports (optional)

External services you must be able to reach: MySQL (`banking_core_db`), MongoDB
(`banking_support_db`), Databricks workspace (SQL + Unity Catalog volume), and
SMTP for alerts (optional).

## 1. Clone and configure

```bash
git clone https://github.com/Nitinx12/Banking-Delta-Lakehouse.git
cd Banking-Delta-Lakehouse
cp .env.example .env          # Windows: copy .env.example .env
```

Edit `.env` with real credentials for PostgreSQL, MySQL, MongoDB, Databricks,
Spark, Airflow and SMTP. Never commit `.env`. The contract is enforced by
`tests/smoke/test_env_contract.py` — every `require()`d variable must be present.

## 2. Install dependencies

```bash
make install        # uv sync --group dev
make hooks          # git config core.hooksPath .githooks  (mandatory)
```

On Windows without Make: `tasks install` then `tasks hooks`.

## 3. Verify the toolchain (no DB, no network)

```bash
make ci             # lint + contracts + sql-lint + coverage + smoke + report fixtures
```

This is the same gate CI runs. Fix any failure before continuing.

## 4. Bootstrap the PostgreSQL warehouse

Apply the ordered, idempotent scripts under `sql/scripts/` (in numeric order,
skipping `00_create_database` if the DB already exists and `05_switch_*` once
the flip is done):

```bash
# disposable DB only
ALLOW_SQL_SMOKE=1 make sql-smoke
```

Then seed watermarks for the first incremental run of new tables (never for
MySQL, which is full-load):

```bash
python scripts/seed_watermarks.py --dry-run
python scripts/seed_watermarks.py
```

## 5. Start the Airflow stack (optional)

```bash
cd airflow
cp .env.airflow.example .env.airflow   # fill real secrets
docker compose --env-file .env.airflow up airflow-init   # must exit 0
docker compose --env-file .env.airflow up -d
# or from the repo root: make up / make down (adds dev bind mounts + GIT_SHA)
```

UI: http://127.0.0.1:8080. The DAGs are created **paused** — un-pause
`banking_delta_daily` and `banking_report_weekly` deliberately.

## 6. Start the dashboard (optional)

```bash
cd dashboard
python -m venv .venv && .venv\Scripts\activate   # or source .venv/bin/activate
pip install -r requirements.txt
cp .streamlit/secrets.toml.example .streamlit/secrets.toml
streamlit run app.py                            # http://localhost:8501
```

The dashboard is read-only and shows only published Databricks marts.

## 7. Run the pipeline

Full gated run (writes to the warehouse **and** Databricks):

```bash
make daily          # or: python main.py
```

Single layer or step:

```bash
python main.py --list                  # show the 9 steps
python main.py --only staging-load
make staging && make dq-staging
make analytics && make dq-analytics
make marts && make dq-marts
make publish
```

Extracts only:

```bash
python scripts/run_jobs.py              # mongo -> databricks -> mysql
python scripts/run_jobs.py --sources mongo
```

## 8. Reports

```bash
make report-fixture     # render every fixture, no TeX, no DB
make report-pdf         # compile every fixture to PDF (needs latexmk)
make report             # daily report against the warehouse in .env
make report-incident RUN=<dag run id>
make report-weekly
```

## 9. Tests

```bash
make test               # unit + smoke
make unit               # pure, isolated
make smoke              # imports, CLIs, repo/SQL/env contracts
make spark-smoke        # local Spark (needs Java)
ALLOW_SQL_SMOKE=1 make integration   # disposable Postgres
make cov                # unit + coverage
```

## 10. Windows notes

Use `tasks.bat <target>` instead of `make <target>`; the two are kept in sync by
`tests/smoke/test_make_parity.py`. Examples: `tasks ci`, `tasks daily`,
`tasks report-fixture`.

## 11. Where to go next

| Doc | What it covers |
| --- | --- |
| `ARCHITECTURE.md` | Blueprint: layers, flow, gates, contracts |
| `docs/PIPELINE.md` | Daily pipeline end to end |
| `docs/DEPLOYMENT.md` | Environments and rollout |
| `docs/RUNBOOK.md` | Operating the pipeline day to day |
| `docs/TROUBLESHOOTING.md` | Common failures and fixes |
| `docs/TESTING.md` | Test markers, layouts, how to run |
| `docs/AIRFLOW.md` | DAGs, schedule, task gating |
| `docs/CI-CD.md` | Workflows, required checks, release flow |
| `CONTRIBUTING.md` | Branching, commits, hooks |
| `SECURITY.md` | Security policy |

## Safety reminders

- Pipeline targets act on the environment `.env` points at — confirm it first.
- Never commit `.env`, `airflow/.env.airflow`, `.streamlit/secrets.toml`, tokens.
- Do not run anything against Databricks or a non-dev environment without approval.
- A critical DQ failure blocks publish; never relax a DQ threshold to go green.
- Use `Decimal` / `NUMERIC(18,2)` for money; never `float`.
