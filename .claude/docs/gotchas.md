# Risks & Gotchas — Banking-Delta-Lakehouse

A mission-critical daily lakehouse pipeline with high idempotency requirements.
The system relies on a strict "Gate before Layer" flow and split watermark stores.
Fragility is concentrated in the Spark-to-Postgres JDBC boundary and Databricks transient errors.

## 🚩 Fragile Areas & Tech Debt
- **Databricks Transient Failures**: The official connector can return 400 RESOURCE_EXHAUSTED when warehouses are launching. This is mitigated by `src/utils/connection.py:dbx_call` but remains a potential hotspot for pipeline stalls.
- **MySQL OOM Risk**: Multi-million-row tables can crash the Spark driver. `src/utils/connection.py:mysql_jdbc` uses `useCursorFetch=true` to stream rows, but this depends on the specific MySQL Connector/J version.
- **SQL Linting Debt**: `Makefile:64` (`sql-lint`) is currently red on pre-existing violations in `sql/`. This is tracked as a separate fix branch and should not be ignored in new PRs.
- **Coverage Floor**: Unit test coverage floor is intentionally low (`pyproject.toml:81` `fail_under = 10`). This is a known gap; the standard is to raise this as new tests are added.

## 🔗 Hidden Coupling & Constraints
- **Watermark Split**: There are two distinct watermark stores: `audit.extract_watermarks` (Source $\rightarrow$ Raw) and `audit.etl_watermarks` (Raw $\rightarrow$ Staging). Mixing these or updating them outside their respective transactions breaks idempotency (`ARCHITECTURE.md:283`).
- **Airflow $\leftrightarrow$ Worker Volume**: The `send_pipeline_summary` task runs in the Airflow **scheduler** container but needs reports written by the **worker**. This requires the specific volume mount in `airflow/docker-compose.yml` (see `ARCHITECTURE.md:761`).
- **Report Run-Key Sync**: The regex for sanitizing `run_id` into `run_key` must be identical between `reports/scripts/paths.py` and `airflow/include/banking_airflow/summary.py` to avoid missing attachments (`ARCHITECTURE.md:752`).

## 🚫 "Do Not Edit" Zones & Generated Files
- **Layer Ownership**: Only the designated owners may write to `raw`, `staging`, `analytics`, and `marts` schemas. Hand-editing these tables bypasses the audit trail and watermarking (`ARCHITECTURE.md:276`).
- **Migration Immutability**: Never edit a Flyway migration (`sql/scripts/V<n>__*.sql`) once merged. Always create a new migration file (`AGENTS.md:28`).
- **Contracts**: Files in `contracts/` are validated against JSON schemas. Use `make contracts-sync` to generate missing ones via introspection rather than manual editing (`Makefile:61`).

## 🧪 Flaky Tests & Testing Tiers
- **Hermeticity Gap**: `unit` and `smoke` tests are strictly hermetic (no network/DB). However, `integration` and `sql-smoke` tests require a disposable Postgres instance and `ALLOW_SQL_SMOKE=1`. Running these against a real warehouse is catastrophic (`Makefile:85`).
- **R Analysis Layer**: The `r/` directory is a read-only consumer. Tests in `r/tests/` are safe for CI, but `r-run` is not (`Makefile:226`).

## 🔐 Security & Secrets
- **Secret Loading**: `.env` is read **only** in `src/utils/config.py`. It uses `override=False`, meaning shell/Airflow exports always take precedence (`src/utils/config.py:16`).
- **JDBC Leakage**: Secrets are passed as separate `user`/`password` parameters in `src/utils/connection.py` to prevent them from appearing in the JDBC URL logs.
- **Audit Redaction**: `audit.pipeline_errors` is designed to be secret-redacted before insertion (`ARCHITECTURE.md:393`).

## ❓ Open Questions / UNVERIFIED
- **Spark JVM Versions**: `Makefile:80` mentions support for Java 8/11/17/21; verified stability across all four on Windows targets is unconfirmed.
- **SCD1 History Volume**: The `staging.scd1_history` table grows monotonically; a pruning strategy for this history is not yet implemented in the daily pipeline.
- **R-Layer Resource Consumption**: The `r/main.R` analysis is read-only but may perform heavy aggregations on `marts`; impact on production DB performance during concurrent runs is unverified.
