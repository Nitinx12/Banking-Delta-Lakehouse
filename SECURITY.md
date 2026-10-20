# Security Policy — Banking-Delta

## Reporting a vulnerability

Do **not** open a public issue for a security problem. Use GitHub's private reporting
(Security tab → "Report a vulnerability") on this repository, or contact the maintainer
(`@Nitinx12`). Include: what you found, how to reproduce it, and the impact you expect.

Please redact secrets in your report — send a fingerprint or the variable name, not the
value.

## Scope

In scope: the pipeline code (`src/`, `scripts/`, `main.py`), SQL (`sql/`,
`tests/data-quality/`), orchestration (`airflow/`), the dashboard (`dashboard/`) and the
CI/CD wiring (`.github/`, `.githooks/`).

Out of scope: findings that require production credentials you were not given, and
pre-existing open items already listed in `repo_detailes.md` §16.3.

## How secrets are handled here

- `.env`, `airflow/.env.airflow` and `.streamlit/secrets.toml` are git-ignored; only the
  `.example` templates are committed, with placeholder values.
- Pre-commit refuses to stage `.env`, `*.pem`, `*.key`, `id_rsa`.
- `make leaks` / the `leaks` CI job scan full history with gitleaks (`.gitleaks.toml`).
- Mail and audit redaction (`airflow/include/banking_airflow/redact.py`,
  `src/utils/audit._redact`) strip URL credentials, `password=`/`token=` pairs, PEM blocks
  and long base64/hex — defense-in-depth, **not** a licence to log secrets.
- Never log row values or credentials; log counts, names and statuses only.

## If a secret is exposed

1. Rotate/revoke it immediately — assume it is compromised.
2. Tell the maintainer; do not just delete the commit (history keeps it).
3. Add it to the gitleaks allow-list only as a placeholder, never the real value.
