@echo off
REM tasks.bat - Windows mirror of the Makefile. Keep targets in sync:
REM tests/smoke/test_make_parity.py fails if a Makefile target is missing here.
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

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
for %%T in (help install hooks lint format sql-lint unit cov smoke test spark-smoke sql-smoke integration smoke-live leaks ci run-jobs staging analytics marts publish dq-raw dq-staging dq-analytics dq-marts dq daily clean) do (
  if /i "%TARGET%"=="%%T" goto :t_%%T
)
echo Unknown target: %TARGET%
echo Run "tasks help" for the list.
exit /b 2

:t_help
echo Usage: tasks ^<target^> [extra args]
echo.
echo Setup     : install hooks
echo Static    : lint format sql-lint
echo Tests     : unit cov smoke test spark-smoke sql-smoke integration smoke-live
echo Security  : leaks
echo Gate      : ci   (lint + sql-lint + unit + smoke)
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
call :t_sql-lint || exit /b 1
call :t_unit || exit /b 1
call :t_smoke || exit /b 1
echo ci OK
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
