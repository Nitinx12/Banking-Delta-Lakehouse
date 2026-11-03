---
name: generate-reports
description: Build daily, incident and weekly PDF reports (fixtures or against the live warehouse).
trigger: report pdf, daily report, incident report, weekly digest, report fixture, latexmk
---

# Generating Reports

The reporting layer renders TeX/PDF reports from warehouse + audit data.
**`docs/REPORTING.md` governs all report code** — §3 (rules for agents) and
§13 (tests) override `AGENTS.md` for anything under `reports/`.

## Targets

```bash
make report-fixture                 # render every fixture context, no TeX, no DB (part of make ci)
make report                         # daily report against the warehouse in .env
make report-incident RUN=<dag run id>   # incident report for one DAG run
make report-weekly                  # weekly digest
make report-pdf                     # compile fixtures to PDF (needs latexmk)
make report-tex                     # fixture compile + log/page budget checks (pytest -m tex)
make report-docker                  # compile inside the TeX image (docker)
make report-clean                   # delete build/output artefacts
```

Windows: `tasks.bat <target>` (same names; `RUN` is read from `%RUN%`).
Direct builder (what the make targets call):

```bash
python -m reports.scripts.build --all-fixtures --no-pdf
python -m reports.scripts.build --kind daily --dag-id banking_delta_daily
python -m reports.scripts.build --kind incident --dag-id banking_delta_daily --dag-run-id <id>
python -m reports.scripts.build --kind weekly --dag-id banking_report_weekly
```

## Fixture vs warehouse

- **Fixtures** (`make report-fixture` / `--all-fixtures`) are hermetic: canned
  contexts, no database, no TeX — this is the CI-safe path and must stay green.
- **Live reports** (`make report`, `report-incident`, `report-weekly`) read the
  warehouse the environment points at; incident/weekly need Airflow run history
  (see `docs/REPORTING.md` §11 for DAG/mail integration).

## Environments and gates

- Every render emits a verdict (`INFO` / `MINOR` / `MAJOR` / `CRITICAL`) from
  the run's severity rules — never hardcode a friendlier verdict.
- Output lands under `reports/output/` (+ `reports/figures/`); `make report-clean`
  removes them. Reports are read-only consumers of the warehouse.

## Tests (§13)

- `make report-fixture` is part of `make ci` — a fixture render failure fails CI.
- `make report-tex` runs `pytest -m tex` (needs `latexmk`); it enforces log and
  page budgets. Do not skip or relax it to go green.
- Unit tests live in `tests/unit/reports/` (`make unit`).

## Typical flows

```bash
# Sanity-check report code without TeX or DB
make ci

# Produce a PDF locally (needs latexmk installed)
make report-pdf

# Investigate a failed scheduled run end-to-end
make report-incident RUN=<airflow dag run id>
```

## Done Checklist

- [ ] `make report-fixture` renders all fixtures without warnings.
- [ ] Live report only run against the intended environment (check `.env` first).
- [ ] `make report-tex` passes when TeX output changed.
- [ ] Report-specific rules followed from `docs/REPORTING.md` §3/§13.
