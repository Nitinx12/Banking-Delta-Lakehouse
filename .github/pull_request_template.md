# PR template — matches docs/GITWORKFLOWS.md. Title = the Conventional Commit summary.
## What and why
<one paragraph; link the issue if any>

## Changes
- <bullet per notable change>

## How it was tested
| Command | Result |
|---|---|
| `make ci` | ✅ / ❌ |
| `make cov` | ✅ (xx%) |
| `<extra tier, e.g. make sql-smoke on disposable PG>` | ✅ / not run (reason) |

## Risk and rollback
<what could break; how to revert (revert commit / new migration)>

## Approvals used
<any restricted action a human approved, who/when — or "none">

## Checklist
- [ ] Branch is not `main`; one concern per branch
- [ ] Tests added/updated with the behaviour; a bug fix includes a failing-first regression test
- [ ] No secrets, `.env`, tokens or scratch dirs staged
- [ ] `docs/` updated if behaviour or targets changed
- [ ] Extra tiers the change requires were run, or listed above as not run (needs approval)
