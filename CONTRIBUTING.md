# Contributing — Banking-Delta

Thanks for helping. This is the short version; the authoritative rules are `AGENTS.md`
(agents) and `docs/GITWORKFLOWS.md` (everyone).

## Set up

```bash
make install        # uv sync --group dev (needs uv)
make hooks          # git config core.hooksPath .githooks — mandatory
make ci             # lint + sql-lint + unit + smoke
```

Windows: the same targets exist as `tasks.bat` (`tasks help`, `tasks ci`). See
`docs/TESTING.md` for test tiers and `docs/DEPLOYMENT.md` for full environments.

## The change loop

1. Branch from an up-to-date `main`: `git switch -c fix/<what>` (prefixes: `feature/`,
   `fix/`, `chore/`, `docs/`, `test/`).
2. Write or adjust the test first (see `docs/TESTING.md`).
3. Make the smallest change that passes.
4. Run the narrow test, then `make test`, then `make ci`.
5. Commit with a Conventional Commit message (`type(scope): summary`), one logical change.
6. Push your branch, open a PR (the template loads automatically) and **stop** — merging to
   `main` needs a human.

## Rules that must not break

- Never commit `.env`, tokens, `*.pem`, `*.key`, `id_rsa`, or row-level data.
- Never weaken, skip or delete a test to get CI green — fix the code or ask.
- Never force-push; never edit an already-merged SQL migration (add a new numbered file).
- Watermarks advance only inside the load transaction; the two watermark stores are never
  mixed (`docs/AUDIT.md`).
- Every load must be safe to run twice with the same input.
- A critical DQ failure blocks publish.
- Money is `Decimal` / `NUMERIC(18,2)`; times are timezone-aware UTC.

## Restricted actions (ask first)

Touching Databricks `public`, running `make daily` / `python main.py` / Airflow triggers,
`make sql-smoke` / `integration` / `spark-smoke` / `smoke-live`, merging or pushing to
`main`, and changing pools, SLOs, watermark behaviour or the registry schema. Full matrix
in `AGENTS.md`.

## Where to look

| Need | Doc |
|---|---|
| Pipeline and layers | `docs/PIPELINE.md` |
| Git, branches, hooks, PRs | `docs/GITWORKFLOWS.md` |
| Tests | `docs/TESTING.md` |
| Data-quality gate | `docs/DATA-QUALITY.md` |
| Audit and watermarks | `docs/AUDIT.md` |
| Orchestration | `docs/AIRFLOW.md` |
| Deploy / configure | `docs/DEPLOYMENT.md` |
| Operate / recover | `docs/RUNBOOK.md` |
| It is broken | `docs/TROUBLESHOOTING.md` |
| Data contracts | `docs/CONTRACTS.md` |
