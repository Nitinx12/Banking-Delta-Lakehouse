# =============================================================================
# Banking-Delta-Lakehouse task runner (GNU Make >= 3.82).
# Windows / cmd.exe users: use tasks.bat (same target names).
# CI calls these same targets, so `make ci` green locally == CI green.
#
# Windows GNU Make ignores SHELL and runs recipes in cmd.exe, so every recipe
# must be portable: no POSIX-only commands, no shell `$$` or `%VAR%` writes,
# double quotes around Rscript -e. tests/smoke/test_make_parity.py enforces it.
#
#   make help
#   make unit ARGS="-k audit -x"
# =============================================================================

SHELL         := bash
.SHELLFLAGS   := -e -o pipefail -c
.DEFAULT_GOAL := help

UV       ?= uv
PY       ?= $(UV) run python
PYTEST   ?= $(UV) run pytest
RUFF     ?= $(UV) run ruff
SQLFLUFF ?= $(UV) run sqlfluff
ARGS     ?=

.PHONY: help install hooks lint format contracts contracts-sync sql-lint unit cov smoke spark-smoke \
		sql-smoke integration smoke-live test leaks ci up down run-jobs run-notebooks staging analytics \
		marts publish dq-raw dq-staging dq-analytics dq-marts dq daily clean \
		load-raw-csv export-raw-csv \
		report-fixture report-pdf report-tex report-docker report-clean report \
		report-incident report-weekly \
		r-restore r-lint r-test r-cov r-run r-docker-build r-docker-run \
		setup-env monitor-logs ## @see R.md §8.4


##@ Setup
help: ## Show this help
	@$(PY) scripts/make_help.py

setup-env: ## Initialize .env files from templates (ARGS="--non-interactive")
	bash scripts/setup_env.sh $(ARGS)

install: ## Install runtime + dev dependencies (uv)
	$(UV) sync --group dev

hooks: ## Enable the repo git hooks (.githooks/)
	git config core.hooksPath .githooks
	@echo "git hooks enabled (core.hooksPath=.githooks)"

##@ Static checks
lint: ## ruff check + ruff format --check
	$(RUFF) check .
	$(RUFF) format --check .

format: ## Auto-fix: ruff check --fix + ruff format
	$(RUFF) check --fix .
	$(RUFF) format .

contracts: ## Validate contracts/ against source-table.schema.json
	$(PY) -m contracts.validate

contracts-sync: ## Generate contracts for registry tables missing one (introspects sources)
	$(PY) scripts/sync_contracts.py

sql-lint: ## sqlfluff lint (postgres dialect) on sql/ and tests/
	$(SQLFLUFF) lint sql tests --dialect postgres

##@ Tests (no network, no DB)
unit: ## Unit tests (pure, isolated)
	$(PYTEST) -m unit $(ARGS)

cov: ## Unit tests + coverage (threshold = fail_under in pyproject.toml)
	$(PYTEST) -m unit --cov --cov-report=term-missing --cov-report=xml $(ARGS)

smoke: ## Smoke tests (imports, CLIs, repo/SQL/env contracts)
	$(PYTEST) -m smoke $(ARGS)

test: ## unit + smoke
	$(PYTEST) -m "unit or smoke" $(ARGS)

spark-smoke: ## Local-Spark tests (needs Java 8/11/17/21)
	$(PYTEST) -m spark $(ARGS)

##@ Tests that need a database
sql-smoke: ## Apply bootstrap + procedures to a DISPOSABLE Postgres (ALLOW_SQL_SMOKE=1)
	$(PY) scripts/apply_sql_smoke.py

integration: ## Behavioural tests on a disposable Postgres (ALLOW_SQL_SMOKE=1)
	$(if $(filter 1,$(ALLOW_SQL_SMOKE)),,$(error Refusing: set ALLOW_SQL_SMOKE=1 (disposable DB only)))
	$(PYTEST) -m integration $(ARGS)

smoke-live: ## READ-ONLY health checks against the configured environment (real creds)
	$(PYTEST) -m live $(ARGS)

##@ Security
leaks: ## gitleaks over git history (needs gitleaks installed)
	$(if $(filter True,$(shell $(PY) -c "import shutil;print(bool(shutil.which('gitleaks')))")),,$(error gitleaks not found: https://github.com/gitleaks/gitleaks#installing))
	gitleaks git --redact -v --config .gitleaks.toml

##@ Gate
ci: ## Fast local gate == CI: lint + contracts + sql-lint + coverage + smoke + report fixtures
	$(MAKE) lint
	$(MAKE) contracts
	$(MAKE) sql-lint
	$(MAKE) cov
	$(MAKE) smoke
	$(MAKE) report-fixture
	@echo "ci OK"

##@ Airflow stack (base + dev override, as the local stack runs)
DC := docker compose -f airflow/docker-compose.yml -f airflow/docker-compose.dev.yml \
	--env-file airflow/.env.airflow

load-raw-csv: ## [0] Land data/raw CSVs into raw (fresh clone, no source systems)
	$(PY) scripts/load_raw_csv.py $(ARGS)

export-raw-csv: ## [0] Re-export data/raw CSVs from the live sources (needs creds)
	$(PY) scripts/export_raw_csv.py $(ARGS)

# GIT_SHA is exported only for `up`: compose labels the stack with it (else "unknown").
up: export GIT_SHA := $(shell git rev-parse --short HEAD)$(shell git diff --quiet || echo -dirty)
up: ## Start the local Airflow stack (GIT_SHA = local HEAD, -dirty if uncommitted)
	$(DC) up -d

down: ## Stop the local Airflow stack
	$(DC) down

##@ Pipeline (acts on the environment .env points at!)
run-jobs: ## [1] Extract: mongo -> databricks -> mysql (ARGS="--sources mongo")
	$(PY) scripts/run_jobs.py $(ARGS)

run-notebooks: ## Execute the project notebooks (ARGS="--notebooks mysql")
	$(PY) scripts/run_notebooks.py $(ARGS)

staging: ## [2] CALL staging.sp_load_all()
	$(PY) main.py --only staging-load

analytics: ## [3] CALL analytics.sp_load_all()
	$(PY) main.py --only analytics-load

marts: ## [4] CALL marts.sp_load_all()
	$(PY) main.py --only marts-load

publish: ## [5] Publish marts to Databricks Delta
	$(PY) src/jobs/publish_marts.py $(ARGS)

dq-raw: ## DQ gate: raw
	$(PY) scripts/run_raw_tests.py $(ARGS)

dq-staging: ## DQ gate: staging
	$(PY) scripts/run_staging_tests.py $(ARGS)

dq-analytics: ## DQ gate: analytics
	$(PY) scripts/run_analytics_tests.py $(ARGS)

dq-marts: ## DQ gate: marts
	$(PY) scripts/run_marts_tests.py $(ARGS)

dq: ## All four DQ suites, in layer order
	$(MAKE) dq-raw
	$(MAKE) dq-staging
	$(MAKE) dq-analytics
	$(MAKE) dq-marts

daily: ## Full gated run: a DQ failure stops everything downstream (incl. publish)
	$(MAKE) run-jobs
	$(MAKE) dq-raw
	$(MAKE) staging
	$(MAKE) dq-staging
	$(MAKE) analytics
	$(MAKE) dq-analytics
	$(MAKE) marts
	$(MAKE) dq-marts
	$(MAKE) publish

##@ Reports
report-fixture: ## Render every fixture context without TeX (hermetic, part of ci)
	$(PY) -m reports.scripts.build --all-fixtures --no-pdf

report-pdf: ## Compile every fixture to PDF (needs latexmk)
	$(PY) -m reports.scripts.build --all-fixtures

report-tex: ## Compile every fixture and check log and page budget (tex tier)
	$(PYTEST) -m tex $(ARGS)

report-docker: ## Compile the fixtures inside the TeX image (needs docker)
	docker build -t banking-report-tex -f reports/Dockerfile .
	docker run --rm -v "$(CURDIR)/reports/output:/work/reports/output" banking-report-tex

report: ## Daily report against the warehouse the environment points at
	$(PY) -m reports.scripts.build --kind daily --dag-id $(or $(DAG_ID),banking_delta_daily)

report-incident: ## Incident report for one run (RUN=<dag run id>)
	$(PY) -m reports.scripts.build --kind incident --dag-id $(or $(DAG_ID),banking_delta_daily) --dag-run-id $(RUN)

report-weekly: ## Weekly digest against the warehouse
	$(PY) -m reports.scripts.build --kind weekly --dag-id $(or $(DAG_ID),banking_report_weekly)

report-clean: ## Delete generated report artefacts
	$(PY) scripts/clean.py --reports

##@ Housekeeping
clean: ## Remove caches and coverage output (keeps .spark/ jar cache)
	$(PY) scripts/clean.py

monitor-logs: ## Monitor and cleanup log files (ARGS="clean -y")
	bash scripts/monitor_logs.sh $(ARGS)

##@ R targets (R.md §8.4)
r-restore: ## install pinned packages
	Rscript -e "renv::restore(project = 'r')"

r-lint:      ## style + static checks
	Rscript -e "lintr::lint_package('r')"

r-test:      ## hermetic unit + contract tests — safe for ci
	Rscript -e "testthat::test_local('r')"

r-cov:       ## coverage report with floor — safe for ci
	Rscript -e "cov <- covr::package_coverage('r', type = 'tests'); pct <- covr::percent_coverage(cov); message(paste0('coverage: ', round(pct, 1), '%')); if (pct < 60) quit(status = 1)"

r-run:       ## full analysis against the real warehouse — NOT part of ci
	Rscript r/main.R

r-docker-build:  ## build the image (needs Docker) — NOT part of ci
	docker build -t banking-delta-r --build-arg GIT_SHA=$(shell git rev-parse --short HEAD) r/

r-docker-run:    ## run in the container against the real warehouse — NOT part of ci
	docker run --rm --env-file r/.env.r -v "$(CURDIR)/r/output:/app/output" banking-delta-r
