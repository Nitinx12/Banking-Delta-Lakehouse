# Data Contracts

A **data contract** is a checked-in JSON file that pins the shape of one table as
it crosses a boundary. In this project the boundary is **source → `raw` landing**:
a contract states what the source system is allowed to send, what the pipeline
promises to store, and how the table is quality-checked. If the contract is
valid, the pipeline has a right to assume the data conforms; if the source
changes shape, the contract is what fails first — in CI, before the run.

Contracts live under `contracts/`, one file per table, validated by
`contracts/validate.py`, and they are the machine-readable companion to
`audit.source_tables` in `sql/scripts/03_register_sources.sql`.

```
contracts/
├── source-table.schema.json     # JSON Schema (draft 2020-12) — the contract of contracts
├── registry.json                # mirror of audit.source_tables (all 10 landing tables)
├── validate.py                  # validator used by pre-commit, make contracts and CI
├── __init__.py
├── mysql/
│   ├── accounts.json            # one file per landed table
│   └── customers.json
├── mongodb/
│   └── support_tickets.json
├── databricks/
│   └── transactions.json
└── example_table/               # worked template (skipped by registry check)
    └── example_table.json
```

There are two ways to read validity:

- **`source-table.schema.json`** — the JSON Schema, for tooling and editors.
- **`contracts/validate.py`** — the enforced judgements (naming, referential
  integrity against `columns`, money types, watermark rules), run in CI. The
  schema and the validator are kept in step; when they disagree, the validator
  wins because it is what the gate runs.

## File format

Every field is defined in `source-table.schema.json`. A full example:

```json
{
  "contract_version": 1,
  "name": "accounts",
  "description": "MySQL account master. Full load; amounts are NUMERIC(18,2), never float.",
  "source": "mysql_source",
  "source_schema": "banking_core_db",
  "source_table": "accounts",
  "target_schema": "raw",
  "target_table": "accounts",
  "business_key": ["account_id"],
  "load_strategy": "full",
  "num_partitions": 4,
  "columns": [
    { "name": "account_id", "type": "bigint", "nullable": false, "key": true },
    { "name": "balance", "type": "numeric(18,2)", "nullable": true }
  ],
  "quality": {
    "row_count": { "mode": "source_vs_landed_exact", "severity": "ERROR" },
    "freshness": {
      "mode": "max_loaded_at_within_window",
      "window": "PT24H",
      "compare": "landing_loaded_at",
      "severity": "WARNING"
    }
  },
  "owner": "banking-data-platform",
  "tags": ["master-data"]
}
```

### Field reference

| Field | Required | Rules |
| --- | --- | --- |
| `contract_version` | yes | must be `1`. Bump only with a migration of every contract. |
| `name` | yes | snake_case; equals `target_table`; equals the file name. |
| `description` | yes | ≥ 8 chars; say what the table is and where it comes from. |
| `source` | yes | one of `mongodb_source`, `mysql_source`, `databricks_source`. |
| `source_schema` | yes | e.g. `banking_core_db`, `banking_support_db`, `public`. |
| `source_table` | yes | name in the source system. |
| `target_schema` | yes | must be `raw` for a landing contract. |
| `target_table` | yes | snake_case; matches the file name and `registry.json`. |
| `business_key` | yes | non-empty list of column names that must exist in `columns`. |
| `load_strategy` | yes | `full` or `incremental`. |
| `incremental_column` | if incremental | snake_case (leading `_` allowed, e.g. `_id`). **Null/absent for full loads.** |
| `watermark_strategy` | if incremental | `timestamp`, `numeric` or `objectid`. **Null/absent for full loads.** |
| `match_mode` | no | `strict_gt` (default) or `inclusive_gte`; how the watermark filter compares. |
| `lookback` | no | ISO-8601 duration (`PT6H`) re-read to absorb late arrivals. |
| `num_partitions` | no | integer ≥ 1; read parallelism hint (mirrors `source_tables`). |
| `columns[]` | yes | non-empty, unique `name`, no duplicates, each `type` from the allowed set. |
| `columns[].type` | yes | see the table below. **Money is `numeric(18,2)`, never `float`.** |
| `columns[].nullable` | no | `true` only if the source can genuinely emit null. |
| `columns[].key` | no | mark business-key columns; must be consistent with `business_key`. |
| `columns[].pii` | no | `true` for names, DOB, phone, email; drives masking in marts. |
| `quality.row_count.mode` | yes | `source_vs_landed_exact` or `source_vs_landed_tolerant`. |
| `quality.row_count.tolerance_ratio` | if tolerant | 0–1. |
| `quality.row_count.severity` | yes | `ERROR` blocks publish; `WARNING` only reports. |
| `quality.freshness.mode` | yes | `max_loaded_at_within_window` or `none`. |
| `quality.freshness.window` | if not `none` | ISO-8601 duration, e.g. `PT24H`. |
| `quality.freshness.compare` | no | `landing_loaded_at` (default) or `source_incremental_column`. |
| `quality.freshness.severity` | yes | `ERROR` or `WARNING`. |
| `owner` | no | team or GitHub handle responsible for the contract. |
| `tags` | no | free-form labels (`master-data`, `pii`, `incremental`, …). |

### Allowed column types

Landing types are deliberately Postgres-shaped. Anything else is rejected.

```
bigint  integer  smallint
numeric(18,2)  numeric(5,2)          -- money / rates; never float
double precision                     -- measurements only, never money
boolean  text  date  timestamptz  jsonb
```

- `timestamptz` for every instant. Sources are UTC; naive datetimes are a bug.
- `numeric(18,2)` for money. A CI test fails any `amount`/`balance`/`income`
  column that is not `numeric(18,2)`.
- MongoDB dates arrive as strings and are cast during landing, so the contract
  still declares the *landed* type (`timestamptz`).

## Landed audit columns

Do **not** declare `_batch_id` or `_loaded_at`. Every landing write adds them
(`src/utils/spark_io.py:add_audit_columns`): `_batch_id` is the `table_run_id`
(a UUID) that produced the row and `_loaded_at` is the write timestamp. Both are
owned by the pipeline, so a contract that lists them fails validation.

## Watermarks and idempotency

Contracts are what make a load safe to run twice:

- `incremental_column` + `watermark_strategy` describe the high-water mark. The
  watermark is advanced **only inside the same transaction as the write**, so a
  crash leaves the watermark where the data is. Never mix
  `audit.extract_watermarks` (MySQL/Mongo) with `audit.etl_watermarks`.
- `match_mode: strict_gt` reads strictly newer than the mark (the default).
  `inclusive_gte` re-reads the boundary row; use `lookback` with it to absorb
  late-arriving rows. The write is idempotent, so re-reads are safe.
- `objectid` strategy orders MongoDB documents by `_id`; `created_at` in those
  collections is a plain string and **cannot** be a timestamp watermark.
- `full` loads redefine the table every run; their contract must leave
  `incremental_column` and `watermark_strategy` empty.

## The registry mirror

`contracts/registry.json` is a machine-readable copy of `audit.source_tables`
(all 10 landing tables). A test asserts that for every contract the registry
agrees on `source`, `business_key`, `load_strategy`, `incremental_column` and
`watermark_strategy`. **SQL is the source of truth**: when you register or
change a table, edit `03_register_sources.sql` first, then `registry.json` and
the contract in the same PR.

## Validation

Run it three ways; all of them execute the same code.

```bash
make contracts                                  # all files
uv run python -m contracts.validate             # same thing
uv run python -m contracts.validate contracts/mysql/accounts.json
```

`contracts/validate.py` fails with a path-prefixed reason, e.g.:

```
contract validation failed:
  - contracts/mysql/accounts.json: business_key column 'account' is not in columns
```

The gate runs in:

- **pre-commit** — staged `contracts/**/*.json` must parse *and* validate.
- **pre-push** — every `contracts/**/*.json` must parse.
- **CI** (`make contracts`, Linux and Windows) and **`make ci`** locally.
- **`tests/unit/test_contracts.py`** — discovery, per-file validity, name/type
  rules, registry agreement and negative cases.

## Adding a contract

1. Register the table in `sql/scripts/03_register_sources.sql` (idempotent) and
   apply it to the warehouse.
2. Copy `contracts/example_table/example_table.json` to
   `contracts/<source>/<target_table>.json` and fill in the fields.
3. Add the row to `contracts/registry.json` to match the SQL.
4. Run `make contracts` until clean, then `make ci`.
5. Commit SQL, registry and contract together; the PR template reminds you.

## Changing or removing a contract

- **Non-breaking** (add a nullable column, add an optional field): one PR.
- **Breaking** (rename/retype/drop a column, change a business key or
  watermark): additive-then-migrate. Land the new column, backfill, switch
  readers, then remove the old column in a later PR. Never edit a merged
  contract to match a silent source change — treat it as an incident.
- **Removing a table**: remove it from the SQL registry, `registry.json`, the
  contract file and its tests in the same PR.

## Rules

- JSON only, no comments; `snake_case` names.
- `name`, `target_table` and the file name always agree.
- Money is `numeric(18,2)`; instants are `timestamptz`; never `float`.
- Landing audit columns are pipeline-owned; do not declare them.
- SQL registry is the source of truth; the mirror and contracts follow it.
- The validator is part of the gate. Do not weaken it to make a red build green.
