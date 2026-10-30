---
globs: ["tests/**/*", "src/tests/**/*"]
---
# Testing Rules

## Python Tests
- **Markers:** Use `@pytest.mark` for categorization: `unit`, `smoke`, `spark`, `integration`, `live`.
- **Hermeticity:** `unit` and `smoke` tests must block network/socket access (enforced in `conftest.py`).
- **Validation:** New behavior must include a corresponding test.

## Data Quality (DQ) Suites
- **Structure:** SQL files must be prefixed with numbers (e.g., `01_check.sql`) and have a `00_master_*.sql` entry point.
- **Blocking:** A critical DQ failure must block the publishing process.
- **Execution:** DQ suites are organized by layer (`raw`, `staging`, etc.) in `tests/data-quality/`.
