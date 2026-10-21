# =============================================================================
# Banking-Delta-Lakehouse task runner (GNU Make >= 3.82, bash).
# Windows / cmd.exe users: use make.bat (same target names).
# CI calls these same targets, so `make ci` green locally == CI green.
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
PSQL     ?= psql -v ON_ERROR_STOP=1 -X -q
ARGS     ?=

# Load .env (shell-style) and map the project's PG_* names to libpq's PG* names.
# Already-exported PGHOST/... win. Used only by targets that call psql.
PG_ENV := set -a; [ ! -f .env ] || . ./.env; set +a; \
	export PGHOST="$${PGHOST:-$$PG_HOST}" \
	       PGPORT="$${PGPORT:-$$PG_PORT}" \
	       PGDATABASE="$${PGDATABASE:-$$PG_DB}" \
	       PGUSER="$${PGUSER:-$$PG_USER}" \
	       PGPASSWORD="$${PGPASSWORD:-$$PG_PASS}";

.PHONY: help install hooks lint format contracts sql-lint unit cov smoke spark-smoke \
        sql-smoke integration smoke-live test leaks ci run-jobs staging analytics \
        marts publish dq-raw dq-staging dq-analytics dq-marts dq daily clean \
        report-fixture report-pdf report-tex report-docker report-clean report \
        report-incident report-weekly

##@ Setup
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target> [ARGS=\"...\"]\n"} \
	  /^##@/ {printf "\n%s\n", substr($$0, 5)} \
	  /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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
	@[ "$${ALLOW_SQL_SMOKE:-}" = "1" ] || { \
	  echo "Refusing: set ALLOW_SQL_SMOKE=1 and point PG_* at a THROWAWAY database (never the real warehouse)."; \
	  exit 1; }
	@$(PG_ENV) \
	for f in $$(ls sql/scripts/*.sql | sort | grep -v -e 00_create_database -e 05_switch); do \
	  echo "apply $$f"; $(PSQL) -f "$$f"; \
	done; \
	for d in staging analytics marts; do \
	  for f in $$(ls sql/$$d/*.sql | sort | grep -v -e /00_master -e /99_debug); do \
	    echo "apply $$f"; $(PSQL) -f "$$f"; \
	  done; \
	done; \
	for l in raw staging analytics marts; do \
	  for f in $$(ls tests/data-quality/$$l/*.sql | sort | grep -v /00_master); do \
	    echo "apply $$f"; $(PSQL) -f "$$f"; \
	  done; \
	done
	@echo "sql-smoke OK"

integration: ## Behavioural tests on a disposable Postgres (ALLOW_SQL_SMOKE=1)
	@[ "$${ALLOW_SQL_SMOKE:-}" = "1" ] || { echo "Refusing: set ALLOW_SQL_SMOKE=1 (disposable DB only)."; exit 1; }
	$(PYTEST) -m integration $(ARGS)

smoke-live: ## READ-ONLY health checks against the configured environment (real creds)
	$(PYTEST) -m live $(ARGS)

##@ Security
leaks: ## gitleaks over git history (needs gitleaks installed)
	@command -v gitleaks >/dev/null 2>&1 || { echo "gitleaks not found: https://github.com/gitleaks/gitleaks#installing"; exit 1; }
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

##@ Pipeline (acts on the environment .env points at!)
run-jobs: ## [1] Extract: mongo -> databricks -> mysql (ARGS="--sources mongo")
	$(PY) scripts/run_jobs.py $(ARGS)

staging: ## [2] CALL staging.sp_load_all()
	@$(PG_ENV) $(PSQL) -f sql/staging/00_master_load.sql

analytics: ## [3] CALL analytics.sp_load_all()
	@$(PG_ENV) $(PSQL) -f sql/analytics/00_master_load.sql

marts: ## [4] CALL marts.sp_load_all()
	@$(PG_ENV) $(PSQL) -f sql/marts/00_master_load.sql

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
	$(PYTEST) -m tex

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
	rm -rf reports/build reports/output reports/figures/*.pdf

##@ Housekeeping
clean: ## Remove caches and coverage output (keeps .spark/ jar cache)
	rm -rf .pytest_cache .ruff_cache .coverage coverage.xml htmlcov
	find . -type d -name __pycache__ -not -path "./.venv/*" -prune -exec rm -rf {} +
