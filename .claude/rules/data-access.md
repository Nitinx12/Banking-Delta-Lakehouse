---
globs: ["sql/**/*.sql", "src/jobs/**/*", "src/utils/**/*"]
---
# Data Access Rules

## Layer Ownership
- **Writing:** `landing`, `staging`, `core`, and `mart` layers are written only by the owners listed in `ARCHITECTURE.md`.
- **Direct Edits:** Never hand-edit schemas; always use extractors or stored procedures.

## Watermarks
- **Separation:** Use `audit.extract_watermarks` for source $\rightarrow$ raw and `audit.etl_watermarks` for raw $\rightarrow$ staging. Never mix them.
- **Advancement:** Watermarks must advance only inside the load transaction.
- **Concurrency:** Use `lock_version` for optimistic locking to prevent concurrent run conflicts.

## Query Standards
- **Explicit Columns:** No `SELECT *`. Always use explicit column lists for `SELECT` and `INSERT` statements.
- **Idempotency:** Every load must be safe to run twice with the same input.
