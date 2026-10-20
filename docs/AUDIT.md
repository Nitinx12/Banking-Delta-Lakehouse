# Audit — Banking-Delta

Everything lands in the `audit` schema of the PostgreSQL warehouse, written with plain
`psycopg2`. Audit writes use their **own** short transactions, so a failed data
transaction still leaves a FAILED record behind. Redaction rules: never log row values or
credentials (`AGENTS.md`).

## Data model

```mermaid
erDiagram
    SOURCE_REGISTRY ||--o{ SOURCE_TABLES : registers
    PIPELINE_RUNS ||--o{ TABLE_RUNS : has
    PIPELINE_RUNS ||--o{ PIPELINE_ERRORS : has
    PIPELINE_RUNS ||--o{ DATA_QUALITY_RESULTS : has
    TABLE_RUNS ||--o| PIPELINE_ERRORS : links
    SOURCE_TABLES ||--o{ TABLE_RUNS : configures
    SOURCE_TABLES ||--o{ EXTRACT_WATERMARKS : tracks
    SOURCE_TABLES ||--o{ ETL_WATERMARKS : tracks

    SOURCE_REGISTRY {
        uuid source_id PK
        text source_name
        bool is_enabled
    }
    SOURCE_TABLES {
        uuid config_id PK
        uuid source_id FK
        text source_table
        text target_table
        text business_key
        text load_strategy
        text incremental_column
        text watermark_strategy
        bool is_enabled
    }
    PIPELINE_RUNS {
        uuid pipeline_run_id PK
        text dag_id
        text dag_run_id
        text status
        int successful_tables
        int failed_tables
        timestamptz started_at
        timestamptz ended_at
    }
    TABLE_RUNS {
        uuid table_run_id PK
        uuid pipeline_run_id FK
        text processing_layer
        text target_table
        int attempt_number
        text status
        bigint rows_landed
        text watermark_start
        text watermark_end
    }
    PIPELINE_ERRORS {
        uuid error_id PK
        uuid pipeline_run_id FK
        text error_category
        text severity
        text message
    }
    DATA_QUALITY_RESULTS {
        uuid result_id PK
        uuid pipeline_run_id FK
        text check_name
        text status
        bigint records_failed
    }
    EXTRACT_WATERMARKS {
        uuid config_id FK
        text last_watermark_value
        int lock_version
    }
    ETL_WATERMARKS {
        text table_name PK
        text last_watermark_value
        int lock_version
    }
```

Related tables written by the DQ gate: `audit.dq_run`, `audit.dq_violation`, view
`audit.v_dq_latest` (`docs/DATA-QUALITY.md`).

## Run lifecycle

```mermaid
stateDiagram-v2
    [*] --> RUNNING : start_pipeline_run
    RUNNING --> RUNNING : table_run attempts update counts
    RUNNING --> SUCCESS : finish_pipeline_run (0 failed, 0 running)
    RUNNING --> PARTIAL : finish_pipeline_run (some ok, some failed)
    RUNNING --> FAILED : finish_pipeline_run (all failed)
    RUNNING --> FAILED : finalize_dag_run reaps orphaned RUNNING table_runs
    SUCCESS --> [*]
    PARTIAL --> [*]
    FAILED --> [*]
```

- **`audit.pipeline_runs`** — one row per pipeline execution. From Airflow,
  `ON CONFLICT (dag_id, dag_run_id)` makes the three parallel per-source tasks share
  **one** row. `finish_pipeline_run` rolls table runs up using only the **latest attempt
  per table**; `finalize_dag_run` reaps `RUNNING` `table_runs` left by a killed worker
  first.
- **`audit.table_runs`** — one row per table **attempt** (`attempt_number` increments);
  `RUNNING → SUCCESS / FAILED / SKIPPED`, row counts, watermarks, duration,
  `execution_metadata` jsonb. `fail_stale_runs(6h)` reaps crashed rows at job start.
- **`audit.pipeline_errors`** — classified (`CONNECTION` / `CONCURRENCY` / `SPARK` /
  `DATA` / `UNKNOWN`), secret-redacted, linked from `table_runs.error_id`.

## The two watermark stores (never mix them)

```mermaid
flowchart LR
    subgraph EXT["extract layer"]
        SRC[("source")]
        RAW[("raw.<table>")]
        EW[("audit.extract_watermarks<br/>last source value landed")]
        SRC -->|"Spark read window"| RAW
        RAW -.->|advance in same transaction| EW
        EW -.->|next window start| SRC
    end
    subgraph STG["staging layer"]
        RAW2[("raw.<table>")]
        STG2[("staging.<table>")]
        TW[("audit.etl_watermarks<br/>last raw value consumed")]
        RAW2 -->|"sp_load_* filters > wm"| STG2
        STG2 -.->|advance in same block| TW
        TW -.->|next window start| RAW2
    end

    classDef src fill:#dbeafe,stroke:#1d4ed8,color:#1e3a8a,stroke-width:2px
    classDef raw fill:#ffedd5,stroke:#c2410c,color:#7c2d12,stroke-width:2px
    classDef staging fill:#cffafe,stroke:#0e7490,color:#164e63,stroke-width:2px
    classDef audit fill:#f1f5f9,stroke:#475569,color:#1e293b,stroke-width:2px
    class SRC src
    class RAW,RAW2 raw
    class STG2 staging
    class EW,TW audit
```

| Table | Layer | Meaning | Advanced by |
|---|---|---|---|
| `audit.extract_watermarks` | extract (source → raw) | last source value landed into raw | `advance_watermark` inside the extract transaction; bootstrapped by `scripts/seed_watermarks.py` |
| `audit.etl_watermarks` | staging (raw → staging) | last raw value consumed into staging | each `staging.sp_load_*` (defaults to `_loaded_at`) |

Both use optimistic locking: `begin_batch` snapshots `lock_version`,
`advance_watermark` updates `WHERE lock_version = expected` and raises a conflict (→
rollback) if another run won. Watermarks advance **only inside the load transaction** —
never advance one by hand (`AGENTS.md`).

## Table registry

`audit.source_registry` + `audit.source_tables` are the config every extractor reads
through `get_enabled_tables`: source/target names, `business_key`, `load_strategy`
(`full`/`incremental`), `incremental_column`, `watermark_strategy`
(`timestamp`/`numeric`/`objectid`), Spark tuning, `is_enabled`.

| Source | Tables | Strategy | Watermark |
|---|---|---|---|
| mongodb_source | support_tickets, card_transactions | incremental | `_id` (objectid) |
| databricks_source | loans, loan_payments, transactions | incremental | `created_at` (timestamp) |
| mysql_source | accounts, branches, cards, customers, employees | full | — |

## Per-extract-run sequence

```mermaid
sequenceDiagram
    autonumber
    participant J as extract_<source>.py
    participant A as utils.audit
    participant S as source system
    participant P as PostgreSQL

    J->>A: fail_stale_runs(6h)
    J->>A: start_pipeline_run(dag_id, dag_run_id)
    loop each enabled table
        J->>A: table_run(...) opens RUNNING row
        alt incremental
            J->>A: get_watermark + begin_batch (lock_version)
            J->>S: MAX(incremental_column)
            J->>A: skip if no new data
        end
        J->>S: read window with Spark
        J->>P: write raw._stg_<table>
        J->>P: ONE transaction: promote_staging + advance_watermark
        J->>P: drop staging table
        J->>A: row_count_source_vs_landed DQ
        J->>A: close table_run (SUCCESS/FAILED/SKIPPED + counts)
    end
    J->>A: finish_pipeline_run
```

## DQ verdicts written by the pipeline

- `log_dq_result` → `audit.data_quality_results` (extract row-count checks, Mongo
  `temporal_values_parsed`, publish `row_count_source_vs_published`).
- The SQL DQ gate writes `audit.dq_run` + `audit.dq_violation`
  (`docs/DATA-QUALITY.md`).

## Rules that must not break

- Watermarks advance only inside the load/extract transaction; the two stores are never
  conflated.
- Every load is safe to run twice with the same input.
- Audit rows survive failure (own transactions; DQ commits before raising).
- `finish_pipeline_run` uses only the latest attempt per table — a regression here flips
  SUCCESS/PARTIAL/FAILED (`docs/TESTING.md`).
