# Update Claude Docs

This skill provides instructions for refreshing project documentation used by AI agents (`CLAUDE.md` and `.claude/docs/`) to ensure they remain synchronized with the current codebase.

## When to run
Run this process whenever there are significant changes to:
- Project architecture or data flow.
- Tech stack or key dependencies.
- Core API contracts or database schemas.
- Deployment or build pipelines.

## Workflow

### 1. Refresh `CLAUDE.md`
`CLAUDE.md` serves as the high-level guide for the agent.
- **Check:** Compare the current implementation against the "Build/Test/Lint" and "Code Style" sections.
- **Update:** If new commands were added to `Makefile` or new linting rules were introduced, update the corresponding sections.
- **Verification:** Run the commands listed in `CLAUDE.md` to ensure they still work.

### 2. Refresh `.claude/docs/`
Detailed documentation in this folder should reflect the current state of the system.
- **Identify Changes:** Use `git diff main...HEAD` to identify modified modules.
- **Update Docs:** For every modified core module, check if there is a corresponding `.md` file in `.claude/docs/`. Update the documentation to reflect new logic, changed parameters, or deprecated functions.
- **Verification:** Ensure all cross-references between docs and code (e.g., file paths) are accurate.

### 3. Cross-Verification
- **Consistency:** Ensure `CLAUDE.md` does not contradict `.claude/docs/`.
- **Redundancy:** Remove obsolete documentation for features that have been deleted.
- **Completeness:** Check `ARCHITECTURE.md` to see if any high-level changes need to be mirrored in the AI-specific docs.
