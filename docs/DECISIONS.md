# Architecture decision log — Banking-Delta-Lakehouse

Why the pipeline is built the way it is. Each entry derives from `ARCHITECTURE.md`,
`docs/`, the code and commit messages. Where no rationale is documented, the entry
describes what the code actually does.

| # | Decision | Status |
|---|---|---|
| 1 | PostgreSQL stored procedures for transformation, not dbt | accepted |
| 2 | Four PostgreSQL layers (`raw` → `staging` → `analytics` → `marts`) | accepted |
| 3 | PySpark used for extraction only | accepted |
| 4 | Watermark/incremental strategy; late-arriving data handling | accepted |
| 5 | Airflow for orchestration, no logic in the DAGs | accepted |
| 6 | Data-quality gates at every layer | accepted |
| 7 | Publish marts to Databricks Delta | accepted |
| 8 | Read-only Streamlit and R consumers | accepted |
| 9 | Data contracts at the source → `raw` landing boundary | accepted |

---

## 1. PostgreSQL stored procedures for transformation, not dbt

**Decision:** Every transform from `raw` through `marts` is a plpgsql stored
procedure (`staging.sp_load_*`, `analytics.sp_load_dim|fact_*`,
`marts.sp_load_mart_*`, masters `sp_load_all`), deployed with `psql -f` and invoked
as one `CALL <schema>.sp_load_all(...)` per layer (`main.py:run_load`).

**Alternatives rejected:** dbt (generated SQL, warehouse-agnostic, lineage and test
ecosystem); Python/PySpark transforms against the warehouse; plain versioned SQL
scripts without procedures.

**Why:** Procedures keep each load in a single transaction with the advisory lock,
`OUT` row counts and the watermark advance (`AGENTS.md` SQL standards;
`ARCHITECTURE.md` §6). The watermark-advance-in-transaction invariant
(`ARCHITECTURE.md` §2.4) is therefore enforced by the procedure that performs the
write, so a crash leaves both the data and the watermark untouched and a retry
re-reads the same window. Idempotency is built from the same transaction boundary:
loads are safe to run twice, and full loads `TRUNCATE` + `INSERT` atomically
(`ARCHITECTURE.md` §6). Commits `de3e289` (analytics procedures), `98157e5` (mart
procedures), `4c5bcba` (deploy via `psql`) show the layer-by-layer adoption. No dbt
configuration exists anywhere in the repo. This explains why procedures meet the
invariants; the repo does not record a separate evaluation of dbt.

**Trade-offs / at larger scale:** Procedures couple the transforms to PostgreSQL and
their lineage is weaker than dbt's graph. I would keep the transactional invariants
but add dbt (or `pg_stat_statements`-driven docs) on top for lineage, documentation
and modular tests once more than one engineer edits the transforms.

## 2. Four PostgreSQL layers (`raw` → `staging` → `analytics` → `marts`)

**Decision:** Landing (`raw`, as-is + `_batch_id`/`_loaded_at`), cleansing
(`staging`, typed/deduped SCD1), modelling (`analytics`, `dim_*`/`fact_*` star
schema) and serving (`marts`, business-shaped `mart_*`), each written only by its
owner and each gated before the next loads (`ARCHITECTURE.md` §5, §14.4).

**Alternatives rejected:** three layers (fold cleansing into landing); a single
schema with views; loading source systems straight into marts.

**Why:** Separation lets the DQ suite test a different contract per layer — schema
at landing, types and keys at staging, grain and orphans at analytics, business
rules at marts (`docs/DATA-QUALITY.md`). Raw stays replayable: any layer can be
rebuilt from `raw` without touching the sources. Layer ownership is a written
invariant (`ARCHITECTURE.md` §14.4), enforced by having exactly one owner per
schema.

**Trade-offs / at larger scale:** Four layers duplicate storage and add a full load
cycle per hop. I would keep the contract boundaries but partition `raw` by
`_loaded_at` and add TTL on `staging._stg_*` artefacts as volume grows; merging
staging into raw would only be reconsidered if landing became typed.

## 3. PySpark used for extraction only

**Decision:** Spark appears only in step 2 (`run_jobs.py` → `extract_*.py` →
`src/utils/spark_io.py`) to read the three sources and write `raw._stg_<table>`.
All transformation is SQL inside PostgreSQL.

**Alternatives rejected:** Spark/Delta for the whole pipeline (Spark SQL
warehouse); plain Python connectors (`pymysql`/`pymongo`) for extraction with no
Spark; ETL logic inside the extract jobs.

**Why:** The sources need what Spark gives — the Mongo connector, JDBC with
exact Postgres types, partitioning hints, and streaming Databricks results through
Arrow to local Parquet (`ARCHITECTURE.md` §4). Transformations run where the
watermarks and transactions live, so the extract layer never decides business
logic. `src/utils/engine.py` exists only to tune and pre-flight-check that one
Spark session.

**Trade-offs / at larger scale:** Two engines (Spark + Postgres) to operate and
tune. I would keep Spark for extraction but move heavy transforms to a Spark/Delta
layer only if Postgres transform time became the bottleneck — today a full run is
~9 min (README metrics), so it is not.

## 4. Watermark/incremental strategy; late-arriving data

**Decision:** Two separate stores — `audit.extract_watermarks` (source → `raw`,
advanced by `advance_watermark` inside the extract transaction) and
`audit.etl_watermarks` (`raw` → `staging`, advanced by each `staging.sp_load_*`).
Both use optimistic `lock_version`; the window is `[last_watermark, MAX(source col)]`
with the lower bound inclusive on MySQL/Mongo and strict `>` on Databricks
(`spark_io._dbx_where`). Full loads (MySQL) are atomic `TRUNCATE` + `INSERT`.

**Alternatives rejected:** one shared watermark table; advancing watermarks after
the commit (outside the transaction); full refresh of every table each run;
event-time watermarks à la Flink.

**Why:** Advancing the mark in the same transaction as the write means a crash
neither loses nor double-counts rows (`ARCHITECTURE.md` §2.4, §6), and the two
stores are never conflated (§14.1). Late arrivals are absorbed by the inclusive
boundary re-read plus an optional `lookback` duration per contract
(`docs/CONTRACTS.md`: "`inclusive_gte` re-reads the boundary row; use `lookback`
with it to absorb late-arriving rows. The write is idempotent, so re-reads are
safe"), and at publish time by re-reading the last N months
(`--lookback` / `PUBLISH_LOOKBACK_MONTHS`, `ARCHITECTURE.md` §9).

**Trade-offs / at larger scale:** The inclusive bound re-reads the boundary row
every run (safe because writes are idempotent, but wasted work at volume). The
known gap is that `PUBLISH_LOOKBACK_MONTHS=0` (default) does not republish old
months — it caused the `mart_support_performance` 193-row gap
(`docs/RUNBOOK.md`); a durable non-zero lookback or periodic `--full` is an open
item. I would default lookback on and add a nightly reconciliation of source vs
published counts (the `publish_reconcile` report already visualises it,
`docs/REPORTING.md`).

## 5. Airflow for orchestration, no logic in the DAGs

**Decision:** Airflow 3.3.2 (CeleryExecutor, Docker Compose) schedules three DAGs;
every task shells out to the same scripts `main.py` runs
(`airflow/dags/banking_delta_daily.py` → `main.py` → `run_jobs.py`). The DAGs hold
wiring, retries, pools and alerting only (`ARCHITECTURE.md` §2.1, §10).

**Alternatives rejected:** cron + shell scripts; Prefect/Dagster; putting pipeline
logic directly in DAG tasks; running only by hand via `main.py`.

**Why:** "One way to run the pipeline" — Airflow adds scheduling, retries, pools
and alerting without ever diverging from the manual path (`ARCHITECTURE.md` §2.1).
The design earns its keep operationally: `preflight` fails in seconds on missing
Java/disk/warehouse, DQ-gate tasks use `retries=0` because a data problem does not
fix itself, `banking_watchdog` reads `audit.pipeline_runs` and stays silent when
healthy (§10). Commits `a99af09` (Airflow/deployment/runbook guides) and
`bfc6e32` (`decide_status` fails closed) document the operational hardening.

**Trade-offs / at larger scale:** A Celery + Redis + Postgres stack is heavy for a
single maintainer. I would keep Airflow (it is already logic-free and testable)
but move to a managed/remote executor and split the `spark_jvm` pool weights per
source as concurrency grows; the watchdog and `all_done` finalisers would stay.

## 6. Data-quality gates at every layer

**Decision:** Each layer has a SQL suite under `tests/data-quality/{layer}/` whose
files define `audit.dq_<layer>_<check>()` procedures; they write `audit.dq_run` +
`audit.dq_violation`, **`COMMIT` the verdict before `RAISE`**, and the runner's
non-zero exit blocks the next layer and publish (`ARCHITECTURE.md` §8).

**Alternatives rejected:** Great Expectations — explicitly not used
(`CLAUDE.md`: "Validation: SQL DQ suites, not Great Expectations"); CI-only tests
that never look at the loaded data; spot-check/sampling gates; Python assertions
after the load.

**Why:** The gate tests *the data in the warehouse*, not the code — a contract
drift or upstream hole must stop publish before a consumer sees it
(`docs/DATA-QUALITY.md`). Commit-before-raise is the one intentional `COMMIT` in
SQL so the failure reason survives the rollback (`ARCHITECTURE.md` §8). The check
catalogue (metadata, keys, dates, orphans, ranges, schema, completeness,
duplicates, domains, reconciliation) is enforced per file, and
`tests/smoke/test_sql_contract.py` pins the per-file contract in CI.

**Trade-offs / at larger scale:** SQL checks are tied to the Postgres dialect and
their catalogue is hand-maintained. I would keep them as the gate but add
cross-system reconciliation (source vs raw vs Delta row counts per key) as a
fifth suite, and generate the check list from the contracts so a new contract
column cannot ship without a check.

## 7. Publish marts to Databricks Delta

**Decision:** Step 10 (`src/jobs/publish_marts.py`) reads PostgreSQL `marts.mart_*`
windowed by the watermark read **from the Delta target itself**, writes local
Parquet via pyarrow, uploads to a Unity Catalog volume and runs one
`MERGE INTO … USING read_files(...)` (keyed marts) or `INSERT OVERWRITE`
(snapshots) (`ARCHITECTURE.md` §9).

**Alternatives rejected:** row-by-row JDBC inserts into Delta; external
tables/federation reading Postgres directly from Databricks; replicating with
Debezium/CDC; making the dashboard query PostgreSQL.

**Why:** The dashboard and R layer consume Databricks SQL, so marts must exist
there; reading the watermark from the target makes publish self-incrementing with
no extra state (`ARCHITECTURE.md` §9). Parquet + `read_files` avoids a JDBC
driver inside Databricks and keeps the whole publish idempotent (MERGE on keys).

**Trade-offs / at larger scale:** The documented gap is the publish lookback: with
`PUBLISH_LOOKBACK_MONTHS=0` late/edited rows in older months are not republished
(`docs/RUNBOOK.md`, the 193-row `mart_support_performance` gap;
`docs/REPORTING.md` says `publish_reconcile` exists because of it). I would turn a
non-zero lookback on by default, add a nightly source-vs-Delta count gate, and
consider Delta Sharing if consumers multiply.

## 8. Read-only Streamlit and R consumers

**Decision:** The Streamlit dashboard (`dashboard/`) and the R layer (`r/`) only
`SELECT` from published Databricks Delta marts; neither ever writes to any layer
(`dashboard/README.md`, `docs/R.md` §0, `ARCHITECTURE.md` colour legend: indigo =
read-only consumers).

**Alternatives rejected:** consumers writing results back into the warehouse;
dashboards querying PostgreSQL directly; a serving API with write endpoints;
giving consumers service accounts with DDL rights.

**Why:** Consumers sit behind the publish boundary, so a bad query cannot corrupt
the warehouse — layer ownership (`ARCHITECTURE.md` §14.4) stays intact. The
dashboard caches each `SELECT` for 5 minutes to protect the SQL warehouse
(`dashboard/README.md`), and the R guide states a read-only consumer "must not
weaken any contract in `ARCHITECTURE.md` §14". The report collector is guarded by a
test that issues only `SELECT` statements (`docs/TESTING.md`).

**Trade-offs / at larger scale:** Read-only means every new derived figure must
first be modelled into a mart (slow for ad-hoc work). I would keep the rule for
anything shared, and add a sandbox schema/consumer with quotas for exploration
instead of relaxing the marts' read-only contract.

## 9. Data contracts at the source → `raw` landing boundary

**Decision:** One JSON contract per source table under `contracts/`, a
`registry.json` mirroring `audit.source_tables`, a JSON Schema
(`source-table.schema.json`) and `contracts/validate.py` run by `make contracts`,
the pre-commit hook and CI — the contract pins what a source may send before any
row lands (`docs/CONTRACTS.md`).

**Alternatives rejected:** contracts at every layer boundary; no contracts
(schema-on-read); contracts expressed only as database migrations; contracts
derived at runtime from `information_schema`.

**Why:** "If the source changes shape, the contract is what fails first — in CI,
before the run" (`docs/CONTRACTS.md`). It is the machine-readable companion to
`audit.source_tables`, so extract config and schema expectations cannot drift
apart. Commit `850b790` (`feat(contracts): add validated source landing contracts`)
introduced the schema, registry and validator together with the CI gate.

**Trade-offs / at larger scale:** Contracts cover only the landing boundary;
staging and mart schemas are guarded by DQ `schema_contract` checks instead of
contracts proper. I would extend the same JSON-Schema approach to each layer's
output (staging, analytics, marts) so every hop has a checked-in expectation,
once the mart schemas stabilise.
