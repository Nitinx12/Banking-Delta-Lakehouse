---
globs: ["**/*"]
---
# Security Rules

## Secret Handling
- **Commits:** NEVER commit `.env`, tokens, passwords, or `file.txt`.
- **Logging:** Never log row values or credentials. Use the project logger from `src/utils/logger.py`.
- **Redaction:** Use `_redact` for secrets in logs and audit tables.

## Environment Configuration
- **Usage:** Read `.env` files ONLY in `src/utils/config.py`. 
- **Access:** Use `src/utils/engine.py` for config access instead of scattered `os.environ` calls.
- **Permissions:** Do not modify `.env*` files without explicit user permission.
