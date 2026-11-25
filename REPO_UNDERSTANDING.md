# Repository understanding

## Summary

Banking-Delta-Lakehouse is a daily banking data platform: three read-only source systems are landed into PostgreSQL with PySpark, transformed by SQL procedures through `raw → staging → analytics → marts`, checked by data-quality suites at each layer boundary, published to Databricks Delta, and consumed by a read-only Streamlit dashboard, an R layer and automated reports; Airflow schedules the same steps that `main.py` can run by hand (`ARCHITECTURE.md:7-11`, `ARCHITECTURE.md:145-151`).

## Plain-language architecture

The platform starts with three sources: MySQL contributes five full tables, MongoDB contributes two incremental collections on `_id`, and Databricks `public` contributes three incremental tables on `created_at` (`ARCHITECTURE.md:17-20`, `contracts/registry.json:4-115`, `sql/scripts/03_register_sources.sql:28-182`). `scripts/run_jobs.py` runs one extract subprocess per source in the order mongo, databricks, mysql (`scripts/run_jobs.py:37-42`), and each extractor snapshots a batch window, writes a transient `raw._stg_<table>`, then promotes into `raw` and advances `audit.extract_watermarks` inside one transaction (`ARCHITECTURE.md:219-234`, `ARCHITECTURE.md:239-245`). SQL procedures then build `staging`, `analytics` and `marts`, with DQ gates after each layer and a stop rule that blocks publish on critical failure (`main.py:84-141`, `docs/DATA-QUALITY.md:33-49`). The publisher reads the Delta watermark, writes Parquet through a Unity Catalog volume, and produces Databricks Delta marts (`src/jobs/publish_marts.py:9-12`, `src/jobs/publish_marts.py:401-452`). Airflow 3.3.2 on CeleryExecutor wires the steps and adds scheduling, retries, pools and alerting but contains no pipeline logic (`docs/AIRFLOW.md:3-5`, `airflow/docker-compose.yml:13-17`, `airflow/dags/banking_delta_daily.py:56-74`). Final consumers are read-only: Streamlit, R and reports (`ARCHITECTURE.md:37-57`, `ARCHITECTURE.md:145-151`).

## Verified fact table

| Fact | Verified value | Source file and line |
|---|---|---|
| Platform shape | Daily lakehouse; 3 sources → PySpark → PostgreSQL layers → Databricks Delta → read-only consumers | `ARCHITECTURE.md:7-11` |
| Source systems | MySQL `banking_core_db`, MongoDB `banking_support_db`, Databricks `public` | `ARCHITECTURE.md:17-20`, `contracts/registry.json:6-8,61-63,83-85` |
| Source objects | 10 tables/collections: 5 MySQL + 2 MongoDB + 3 Databricks | `contracts/registry.json:4-115`, `sql/scripts/03_register_sources.sql:28-182` |
| MySQL load strategy | 5 full tables: `accounts`, `branches`, `cards`, `customers`, `employees` | `contracts/registry.json:5-59`, `sql/scripts/03_register_sources.sql:113-182` |
| MongoDB load strategy | 2 incremental collections on `_id` with `objectid` watermark strategy | `contracts/registry.json:60-81`, `sql/scripts/03_register_sources.sql:28-61` |
| Databricks load strategy | 3 incremental tables on `created_at` with `timestamp` watermark strategy | `contracts/registry.json:82-113`, `sql/scripts/03_register_sources.sql:63-111` |
| Extract order | `("mongo", "databricks", "mysql")`, one subprocess per source | `scripts/run_jobs.py:3-11,37-42` |
| Extract retry controls | 180s timeout, 30s retry backoff, 2 attempts | `scripts/run_jobs.py:40-42` |
| Pipeline steps | 10 named steps from `preflight` through `publish` | `main.py:84-141` |
| Stop rule | A failing step stops the run unless `--keep-going` is passed | `main.py:3-6` |
| Warehouse layers | `raw`, `staging`, `analytics`, `marts`, plus cross-cutting `audit` | `ARCHITECTURE.md:29-35`, `ARCHITECTURE.md:275-281` |
| Layer ownership | `extract_*.py`, `staging.sp_load_*`, `analytics.sp_load_*`, `marts.sp_load_*`, `publish_marts.py` own their target layers | `ARCHITECTURE.md:275-290` |
| Watermark stores | `audit.extract_watermarks` for source→raw; `audit.etl_watermarks` for raw→staging and later layers; never mixed | `ARCHITECTURE.md:294-330` |
| Watermark safety | Optimistic locking snapshots `lock_version`, updates with `WHERE lock_version = expected`, and rolls back on conflict | `ARCHITECTURE.md:326-328` |
| Full-load safety | MySQL full loads have no watermark and use atomic `TRUNCATE` + `INSERT` | `ARCHITECTURE.md:329-330` |
| Idempotency | Every load is safe to run twice with the same input | `ARCHITECTURE.md:90-94` |
| Analytics entities | 7 dims and 4 facts | `ARCHITECTURE.md:283-285` |
| Marts | 8 named marts | `ARCHITECTURE.md:286-288`, `sql/marts/01_mart_customer_360.sql`-`sql/marts/08_mart_loan_vintage.sql` |
| DQ check counts | raw 10, staging 10, analytics 13, marts 11; total 44 | `docs/DATA-QUALITY.md:37-44` |
| DQ gate rule | Non-zero exit blocks publish in Airflow and `main.py` | `docs/DATA-QUALITY.md:33-49` |
| DQ audit rule | Each check writes `audit.dq_run` / `audit.dq_violation`, `COMMIT`s, then `RAISE`s | `docs/DATA-QUALITY.md:59-69` |
| Audit model | Runs, errors, source registry, watermarks and DQ verdicts use their own short transactions | `ARCHITECTURE.md:332-410` |
| Airflow version | 3.3.2, CeleryExecutor, Docker Compose | `docs/AIRFLOW.md:3-5`, `airflow/docker-compose.yml:13-17`, `airflow/.env.airflow.example:9-10` |
| Daily DAG | `banking_delta_daily`; timezone default `Asia/Kolkata`; schedule default `0 2 * * *` | `airflow/dags/banking_delta_daily.py:27-29,56-60` |
| DAG count | 3 DAG files: daily, watchdog, weekly | `airflow/dags/banking_delta_daily.py:27`, `airflow/dags/banking_watchdog.py:136,138`, `airflow/dags/banking_report_weekly.py:17,30-32` |
| Watchdog schedule | `banking_watchdog` uses `0 */3 * * *` | `airflow/dags/banking_watchdog.py:136,138` |
| Weekly report schedule | `banking_report_weekly` uses `0 8 * * 1` | `airflow/dags/banking_report_weekly.py:17,30-32` |
| DAG creation state | DAGs are paused at creation | `airflow/docker-compose.yml:13-17` |
| Python version | `requires-python = ">=3.13"` | `pyproject.toml:6` |
| PySpark dependency | `pyspark>=3.5.3,<3.6` | `pyproject.toml:13-14` |
| Streamlit dependency | `streamlit==1.66.1` | `pyproject.toml:25`, `site/requirements.txt:1` |
| Plotly dependency | `plotly>=7.0,<8` | `pyproject.toml:26-27` |
| Money and time types | Money is `NUMERIC(18,2)` / `Decimal`; instants are timezone-aware UTC | `ARCHITECTURE.md:96-98` |
| Current site deployment | Streamlit Community Cloud app; main file `site/site.py`; requirements `site/requirements.txt` | `site/README.md:1-11` |
| Current landing page | One self-contained iframe with local CSS/JS inlined at runtime; replay is labelled illustrative | `site/README.md:21`, `site/site.py:8-16` |
| Current repo links | Driven by one `REPO_URL` constant | `site/scripts/site.js:4,174-184` |
| Current static entrypoint | `site/index.html` contains the static HTML and links local CSS/JS | `site/index.html:1-16,740` |

## Discrepancies and unverified claims

| Item | Side A | Side B | Site decision |
|---|---|---|---|
| PySpark version | README badge says PySpark 4.1 (`README.md:16`) | `pyproject.toml` pins `pyspark>=3.5.3,<3.6` (`pyproject.toml:14`) | Use the dependency pin as truth |
| Streamlit version | README badge says Streamlit 1.62 (`README.md:22`) | `pyproject.toml:25` and `site/requirements.txt:1` pin `streamlit==1.66.1` | Use the pin as truth |
| Mart count | README says 9 marts (`README.md:96`) | Architecture and SQL list 8 (`ARCHITECTURE.md:286-288`, `sql/marts/01_mart_customer_360.sql`-`08_mart_loan_vintage.sql`) | Show 8 |
| DQ count | README says 48 checks: 11/11/14/12 (`README.md:97`) | DQ guide says 44 checks: 10/10/13/11 (`docs/DATA-QUALITY.md:37-44`) | Show 44 |
| Test/coverage claims | README says 786 tests and 91.0% coverage (`README.md:98-99`) | Current repo config only states a 10% coverage floor (`pyproject.toml:82-85`); no fresh test/coverage run was performed in Phase 0 | Treat README figures as unverified; do not put them on the site |
| Runtime/table-size claims | README reports ~9 min median run and 3,005,000-row largest table (`README.md:100-101`) | No Phase 0 verification from live warehouse or audit tables | Treat as unverified; omit from site |
| DAG count | AIRFLOW guide says “Two DAGs” (`docs/AIRFLOW.md:5`) | Three DAG files exist (`airflow/dags/banking_delta_daily.py`, `banking_watchdog.py`, `banking_report_weekly.py`) | Show 3 |
| Bootstrap scripts | Deployment table lists scripts 00–06 only (`docs/DEPLOYMENT.md:64-76`) | `sql/scripts/` also contains `06_switch_mysql_incremental.sql` and `07_dq_pipeline_run.sql` | Do not show a numbered bootstrap list unless it says “selected core scripts” |
| `MART_CONFIG` count | Testing guide says “all 7 marts” (`docs/TESTING.md:117`) | `MART_CONFIG` defines 8 tables (`src/jobs/publish_marts.py:52-113`) | Show 8 |
| Publish behavior | Docstring and current site describe incremental MERGE/INSERT OVERWRITE (`src/jobs/publish_marts.py:9-12`, `site/index.html:492-493,500,508`) | Code forces a full overwrite with empty `where` and always uses `_overwrite_sql` (`src/jobs/publish_marts.py:485-489,518-520`) | Describe the chain as local Parquet → UC volume → Delta overwrite; do not promise MERGE |
| Authority rule | Current site README says architecture and code win over README (`site/README.md:23`) | Architecture says code wins, then fix the file (`ARCHITECTURE.md:3-5`) | Use code first, then architecture |
| Delivery format | Current site is a Streamlit Community Cloud app (`site/README.md:1-11`, `site/site.py:1-16`) | Rebuild target is a static site served from plain files | Preserve existing `site/index.html`, `site/style/`, `site/scripts/site.js`; leave Streamlit files unless asked |
| Inline styles | Current HTML has 20 `style=` attributes (`site/index.html:61,349,371,373,400,402,425,442,444,449,451,478,480,483,514,530,581,606,607,609`) | Rebuild rule is no inline styles | Replace with tokenized classes |
| `!important` usage | Current CSS uses six `!important` declarations (`site/style/streamlit.css:11-13,97-103`) | Rebuild rule is no `!important` | Rewrite Streamlit overrides without `!important` where possible |
| Diagram overflow | SVG has `min-width: 1420px` / `900px` inside a horizontal scroller (`site/style/diagrams.css:31-46`) | No horizontal scroll is allowed at target widths | Rebuild diagram with measured layout and responsive stepper |
| Timeline overflow | Timeline is 10 columns with `minmax(150px, 1fr)` (`site/style/components.css:354-359`) | No horizontal scroll wrapper is allowed for daily-run steps | Rebuild as wrapping cards / vertical stepper |

## Working assumptions

- Rebuild the static files inside `site/` so the existing `index.html`, local `style/` and `scripts/site.js` layout is preserved (`site/index.html:11-15,740`).
- Keep the existing Streamlit pages and app files unchanged unless the rebuild explicitly requires removing them (`site/README.md:7-23`, `site/site.py:1-16`).
- Use `REPO_URL` as the only source for external repo links, as the current JS already does (`site/scripts/site.js:4,174-184`).

## Five things a first-time visitor must understand in under 60 seconds

1. This is one daily pipeline, not a set of unrelated scripts: read-only sources land into PostgreSQL, pass four layers and DQ gates, then publish to Delta for read-only consumers (`ARCHITECTURE.md:7-11`, `ARCHITECTURE.md:37-57`).
2. `main.py` and Airflow are two entry points to the same scripts and SQL; Airflow adds scheduling, retries, pools and alerting only (`ARCHITECTURE.md:87-89`, `main.py:84-141`).
3. Every layer boundary is gated, and a critical DQ failure blocks publish because the verdict is committed before it raises (`ARCHITECTURE.md:90-91`, `docs/DATA-QUALITY.md:33-49,64-65`).
4. Watermarks move only inside the data transaction, the two stores are never mixed, and the same input can be replayed safely (`ARCHITECTURE.md:92-94,294-330`).
5. Layer ownership and types are strict: only the named owner writes each schema, money is `NUMERIC(18,2)` / `Decimal`, and instants are timezone-aware UTC (`ARCHITECTURE.md:96-101,275-290`).
