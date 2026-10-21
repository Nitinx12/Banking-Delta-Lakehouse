# Git workflows — Banking-Delta-Lakehouse

How this repository manages git: branches, commits, hooks, the change loop and PR rules.
Rules for AI agents (`AGENTS.md`) always win on conflict.

## Ground rules

1. One concern per branch, one logical change per commit, small diffs.
2. Branch from an up-to-date `main`; keep branches short-lived (days, not weeks).
3. Conventional Commits; hooks always on — `--no-verify` is forbidden.
4. Never commit `.env`, tokens, `*.pem`, `*.key`, `id_rsa`, `file.txt`.
5. Never force-push; never edit an already-merged SQL migration (add a new numbered file).
6. Never weaken, skip or delete a test to get CI green — fix the code or ask.
7. Tests go in the same commit (or PR) as the behaviour they cover; a bug fix ships with a
   regression test that fails before the fix.

## Branching

| Prefix | Use | Example |
|---|---|---|
| `feature/` | new capability | `feature/publish-lookback-config` |
| `fix/` | bug fix | `fix/summary-task-states` |
| `chore/` | tooling, deps, config, test scaffolding | `chore/test-scaffold` |
| `docs/` | documentation only | `docs/project-docs` |
| `test/` | tests only (fall back to `chore/` if the prefix is disallowed) | `test/audit-redact-unit` |

Lowercase kebab-case. Sync first:

```bash
git fetch origin
git switch main && git pull --ff-only
git switch -c fix/summary-task-states
```

Windows `cmd`/PowerShell use the same commands.

## One-time setup

```bash
make install        # uv sync --group dev
make hooks          # git config core.hooksPath .githooks   (mandatory)
git config --get core.hooksPath   # must print .githooks
```

### Hooks (`.githooks/`)

| Hook | Enforces |
|---|---|
| `commit-msg` | Conventional Commits `type(scope): summary` |
| `pre-commit` | blocks `.env`/`*.pem`/`*.key`/`id_rsa`; `ruff check` + `ruff format --check` on staged Python |
| `pre-push` | fast gate before a push leaves the machine |

`.pre-commit-config.yaml` (the `pre-commit` framework, if you use it) adds whitespace
hygiene, ruff (pinned 0.12.0), sqlfluff (postgres dialect, `sql/` + `tests/`) and a
conventional-commits check. If a hook fails, fix the cause — never bypass it.

## Commit messages

Format: `type(scope): imperative summary` — ≤ 72 chars, no trailing period.
Body explains *why*; reference the issue if any.

Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `chore`, `build`, `ci`, `style`,
`revert`.

Scopes used here: `extract`, `audit`, `spark-io`, `engine`, `publish`, `main`, `airflow`,
`dags`, `sql`, `staging`, `analytics`, `marts`, `dq`, `dashboard`, `make`, `batch`,
`hooks`, `deps`, `tests`, `repo`, `reports`.

```text
fix(airflow): read task states via TaskInstance.get_task_states

summary.py read context["task_states"], which Airflow 3 does not provide,
so green runs emailed a false [FAILED] banner. Fetch states by
(dag_id, run_id) and pass env/git_sha into the summary.

Tests: unit tests for decide_status with real state maps.
```

Hygiene: stage explicitly (`git add <paths>`), review with `git diff --staged`. Never
`git add -A` blindly. Never commit scratch dirs: `.spark/`, `logs/`, `airflow/logs/`,
`.venv/`, `.coverage`, `htmlcov/`, `__pycache__/`.

## The change loop

```text
1  Read AGENTS.md and the relevant docs/ page
2  Sync main, create branch
3  Write/adjust the test FIRST (see docs/TESTING.md — red)
4  Implement the smallest change (green)
5  Narrow test:   uv run pytest path/to/test_x.py -q
6  Fast gate:     make unit smoke   (or: make test)
7  Full gate:     make ci           (= lint + sql-lint + unit + smoke)
8  Extra tiers the change requires (ask first for DB/Spark/live — see docs/TESTING.md)
9  Update docs/Makefile if targets changed (keep Makefile ↔ docs in sync)
10 git add <paths>; git commit   (hooks must pass)
11 git fetch origin; git merge origin/main   (resolve, re-run make ci)
12 git push -u origin <branch>
13 Open PR, then STOP. Do not merge.
```

To keep a branch current, **merge `origin/main` into your branch** — rebasing needs
force-push, which is forbidden. If history is messy, ask the human.

## Pull requests

- Title = the Conventional Commit summary.
- Includes: what/why, how tested (commands + real results), risk, rollback, any approval
  used for restricted actions.
- Aim for one concern, ideally < 400 changed lines excluding generated files.
- Agents open the PR and stop. Merging or pushing to `main` needs a human.

## Permissions

| Action | Allowed without asking | Ask first | Never |
|---|---|---|---|
| Read; `make lint / sql-lint / unit / cov / smoke / test / ci` | yes | | |
| Code/tests/docs on a `feature|fix|chore|docs` branch | yes | | |
| `git add`, `git commit`, push **your own branch**, open PR | yes | | |
| `make spark-smoke`, `make sql-smoke`, `make integration`, `make smoke-live` | | yes | |
| `make daily`, `python main.py`, Airflow trigger (writes to warehouse) | | yes | |
| Merge/push to `main`, tag, release | | yes | |
| Commit `.env`/tokens/keys, write to Databricks `public`, edit a merged migration, force-push, run tests against production | | | never |

## SQL changes

- Schema/procedure changes that affect an existing database go in a **new numbered file**
  (`sql/scripts/NN_<what>.sql`), idempotent, in numeric order. Never edit `00`–`06` once
  merged.
- Procedure files (`sql/{staging,analytics,marts}/NN_*.sql`) are `CREATE OR REPLACE`:
  editing the current file on a branch is fine, but `00_master_load.sql` order must stay
  parent → child.
- Always `make sql-lint`; run `make sql-smoke` (disposable PG, `ALLOW_SQL_SMOKE=1`, ask
  first) when you change procedures.
- New/changed DQ check → `docs/DATA-QUALITY.md`.

## What must not break

- Watermarks advance only inside the load/extract transaction
  (`audit.extract_watermarks` vs `audit.etl_watermarks` — never mix them, `docs/AUDIT.md`).
- Every load is safe to run twice with the same input (idempotent).
- A critical DQ failure blocks publish.
- `raw`, `staging`, `analytics`, `marts` are written only by their owners
  (extracts → raw; `sp_load_*` → staging/analytics/marts; `publish_marts.py` → Databricks).
