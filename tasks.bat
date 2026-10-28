@echo off
REM tasks.bat - Windows mirror of the Makefile. Keep targets in sync:
REM tests/smoke/test_make_parity.py fails if a Makefile target is missing here.
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"
REM Make Rscript available if R is installed in a standard location but not on PATH.
where Rscript >nul 2>&1 || if exist "C:\Program Files\R\R-4.6.1\bin\Rscript.exe" set "PATH=C:\Program Files\R\R-4.6.1\bin;%PATH%"

set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=help"
if not "%~1"=="" shift
set "ARGS="
:collect
if "%~1"=="" goto dispatch
set "ARGS=%ARGS% %~1"
shift
goto collect

:dispatch
for %%T in (help install hooks lint format contracts contracts-sync sql-lint unit cov smoke test spark-smoke sql-smoke integration smoke-live leaks ci up down run-jobs staging analytics marts publish dq-raw dq-staging dq-analytics dq-marts dq daily clean report-fixture report-pdf report-tex report-docker report-clean report report-incident report-weekly r-restore r-lint r-test r-run r-docker-build r-docker-run) do (
  if /i "%TARGET%"=="%%T" goto :t_%%T
)
echo Unknown target: %TARGET%
echo Run "tasks help" for the list.
exit /b 2

:t_help
echo Usage: tasks ^<target^> [extra args]
echo.
echo Setup     : install hooks
echo Static    : lint format contracts sql-lint
echo Tests     : unit cov smoke test spark-smoke sql-smoke integration smoke-live
echo Security  : leaks
echo Gate      : ci   (lint + sql-lint + unit + smoke)
echo Airflow   : up down
echo Reports   : report-fixture report-pdf report-tex report-docker report-clean report report-incident report-weekly
echo Pipeline  : run-jobs staging analytics marts publish dq-raw dq-staging dq-analytics dq-marts dq daily
echo Housekeep : clean
exit /b 0

:t_install
uv sync --group dev || exit /b 1
exit /b 0

:t_hooks
git config core.hooksPath .githooks || exit /b 1
echo git hooks enabled ^(core.hooksPath=.githooks^)
exit /b 0

:t_lint
uv run ruff check . || exit /b 1
uv run ruff format --check . || exit /b 1
exit /b 0

:t_format
uv run ruff check --fix . || exit /b 1
uv run ruff format . || exit /b 1
exit /b 0

:t_contracts
uv run python -m contracts.validate || exit /b 1
exit /b 0

:t_contracts-sync
uv run python scripts\sync_contracts.py %ARGS% || exit /b 1
exit /b 0

:t_sql-lint
uv run sqlfluff lint sql tests --dialect postgres || exit /b 1
exit /b 0

:t_unit
uv run pytest -m unit %ARGS% || exit /b 1
exit /b 0

:t_cov
uv run pytest -m unit --cov --cov-report=term-missing --cov-report=xml %ARGS% || exit /b 1
exit /b 0

:t_smoke
uv run pytest -m smoke %ARGS% || exit /b 1
exit /b 0

:t_test
uv run pytest -m "unit or smoke" %ARGS% || exit /b 1
exit /b 0

:t_spark-smoke
uv run pytest -m spark %ARGS% || exit /b 1
exit /b 0

:t_sql-smoke
if not "%ALLOW_SQL_SMOKE%"=="1" (
  echo Refusing: set ALLOW_SQL_SMOKE=1 and point PG_* at a THROWAWAY database ^(never the real warehouse^).
  exit /b 1
)
echo Apply sql/scripts, sql/{staging,analytics,marts} and tests/data-quality by hand,
echo or use the Make target ^(needs bash + psql^).
exit /b 1

:t_integration
if not "%ALLOW_SQL_SMOKE%"=="1" (
  echo Refusing: set ALLOW_SQL_SMOKE=1 ^(disposable DB only^).
  exit /b 1
)
uv run pytest -m integration %ARGS% || exit /b 1
exit /b 0

:t_smoke-live
uv run pytest -m live %ARGS% || exit /b 1
exit /b 0

:t_leaks
gitleaks git --redact -v --config .gitleaks.toml || exit /b 1
exit /b 0

:t_ci
call :t_lint || exit /b 1
call :t_contracts || exit /b 1
call :t_sql-lint || exit /b 1
call :t_cov || exit /b 1
call :t_smoke || exit /b 1
call :t_report-fixture || exit /b 1
echo ci OK
exit /b 0

:t_up
for /f "delims=" %%G in ('git rev-parse --short HEAD') do set "GIT_SHA=%%G"
git diff --quiet || set "GIT_SHA=%GIT_SHA%-dirty"
docker compose -f airflow/docker-compose.yml -f airflow/docker-compose.dev.yml --env-file airflow/.env.airflow up -d || exit /b 1
exit /b 0

:t_down
docker compose -f airflow/docker-compose.yml -f airflow/docker-compose.dev.yml --env-file airflow/.env.airflow down || exit /b 1
exit /b 0

:t_run-jobs
uv run python scripts\run_jobs.py %ARGS% || exit /b 1
exit /b 0

:t_staging
uv run python main.py --only staging-load || exit /b 1
exit /b 0

:t_analytics
uv run python main.py --only analytics-load || exit /b 1
exit /b 0

:t_marts
uv run python main.py --only marts-load || exit /b 1
exit /b 0

:t_publish
uv run python src\jobs\publish_marts.py %ARGS% || exit /b 1
exit /b 0

:t_dq-raw
uv run python scripts\run_raw_tests.py %ARGS% || exit /b 1
exit /b 0

:t_dq-staging
uv run python scripts\run_staging_tests.py %ARGS% || exit /b 1
exit /b 0

:t_dq-analytics
uv run python scripts\run_analytics_tests.py %ARGS% || exit /b 1
exit /b 0

:t_dq-marts
uv run python scripts\run_marts_tests.py %ARGS% || exit /b 1
exit /b 0

:t_dq
call :t_dq-raw || exit /b 1
call :t_dq-staging || exit /b 1
call :t_dq-analytics || exit /b 1
call :t_dq-marts || exit /b 1
exit /b 0

:t_daily
call :t_run-jobs || exit /b 1
call :t_dq-raw || exit /b 1
call :t_staging || exit /b 1
call :t_dq-staging || exit /b 1
call :t_analytics || exit /b 1
call :t_dq-analytics || exit /b 1
call :t_marts || exit /b 1
call :t_dq-marts || exit /b 1
call :t_publish || exit /b 1
exit /b 0

:t_clean
for /d /r . %%D in (__pycache__) do @if exist "%%D" (echo "%%D" | findstr /i /l /c:".venv" /c:".spark" >nul || rd /s /q "%%D")
for %%D in (.pytest_cache .ruff_cache .mypy_cache htmlcov) do @if exist "%%D" rd /s /q "%%D"
if exist .coverage del /q .coverage
if exist coverage.xml del /q coverage.xml
exit /b 0

:t_report-fixture
uv run python -m reports.scripts.build --all-fixtures --no-pdf || exit /b 1
exit /b 0

:t_report-pdf
uv run python -m reports.scripts.build --all-fixtures || exit /b 1
exit /b 0

:t_report-tex
uv run pytest -m tex %ARGS% || exit /b 1
exit /b 0

:t_report-docker
docker build -t banking-report-tex -f reports\Dockerfile . || exit /b 1
docker run --rm -v "%cd%/reports/output:/work/reports/output" banking-report-tex || exit /b 1
exit /b 0

:t_report
uv run python -m reports.scripts.build --kind daily --dag-id banking_delta_daily || exit /b 1
exit /b 0

:t_report-incident
uv run python -m reports.scripts.build --kind incident --dag-id banking_delta_daily --dag-run-id %RUN% || exit /b 1
exit /b 0

:t_report-weekly
uv run python -m reports.scripts.build --kind weekly --dag-id banking_report_weekly || exit /b 1
exit /b 0

:t_report-clean
if exist reports\build rmdir /s /q reports\build
if exist reports\output rmdir /s /q reports\output
if exist reports\figures\*.pdf del /q reports\figures\*.pdf
exit /b 0
:t_r-restore
Rscript -e "renv::restore(project = 'r')" || exit /b 1
exit /b 0

:t_r-lint
Rscript -e "lintr::lint_package('r')" || exit /b 1
exit /b 0

:t_r-test
Rscript -e "testthat::test_local('r')" || exit /b 1
exit /b 0

:t_r-run
Rscript r\main.R || exit /b 1
exit /b 0

:t_r-docker-build
docker build -t banking-delta-r --build-arg GIT_SHA=unknown r/ || exit /b 1
exit /b 0

:t_r-docker-run
docker run --rm --env-file r/.env.r -v "%cd%\r\output:/app/output" banking-delta-r || exit /b 1
exit /b 0
