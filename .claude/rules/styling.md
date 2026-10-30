---
globs: ["**/*.py", "**/*.sql"]
---
# Styling Rules

## Python Styling
- **Standards:** Follow PEP 8. Format and lint with `ruff`, type-check with `mypy`.
- **Naming:** 
    - Files/Functions: `snake_case`.
    - Constants: `UPPER_SNAKE_CASE`.
    - Classes: `PascalCase`.
- **Types:** Mandatory type hints on every function signature.
- **Documentation:** Short docstrings on public functions.

## SQL Styling
- **Keywords:** Use `UPPERCASE` for all SQL keywords.
- **Identifiers:** Use `snake_case` for names.
- **Linting:** Checked with `sqlfluff` (postgres dialect).

## General
- **Comments:** 
    - Top of file/function: One short line describing purpose.
    - Inline: A few words for "why", never "what".
    - No block comments or section banners.
