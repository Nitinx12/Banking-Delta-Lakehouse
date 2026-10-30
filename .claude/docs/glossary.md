# Project Glossary — Banking-Delta-Lakehouse

This glossary defines the domain terms and project-specific jargon used across the Banking-Delta-Lakehouse codebase. It serves as a reference for engineers to ensure consistent terminology when implementing pipeline changes or documentation.

## Domain Terms

| Term | Definition | References |
| :--- | :--- | :--- |
| **SCD1** | Slowly Changing Dimension Type 1. Overwrites old data with new data to keep only the current state. | `ARCHITECTURE.md:31`, `sql/staging/` |
| **Medallion Architecture** | A data design pattern using layers (Raw $\rightarrow$ Staging $\rightarrow$ Analytics $\rightarrow$ Marts) to incrementally refine data. | `ARCHITECTURE.md:8-9`, `ARCHITECTURE.md:243-248` |
| **Watermark** | A value (timestamp or ID) used to track the last processed record for incremental loads, ensuring idempotency. | `ARCHITECTURE.md:93-94`, `audit.extract_watermarks`, `audit.etl_watermarks` |
| **Mart** | The final serving layer of the warehouse, containing business-shaped tables (KPIs, 360 views) for consumption. | `ARCHITECTURE.md:33`, `ARCHITECTURE.md:248` |
| **Delta Lake** | An open-source storage layer that brings ACID transactions to Apache Spark and big data workloads. | `ARCHITECTURE.md:10`, `ARCHITECTURE.md:37` |
| **Idempotency** | The property where a process can be run multiple times with the same input without changing the result beyond the initial application. | `ARCHITECTURE.md:92`, `AGENTS.md:103` |
| **Star Schema** | A modeling technique using central Fact tables surrounded by Dimension tables. | `ARCHITECTURE.md:247`, `ARCHITECTURE.md:271-273` |

## Project-Specific Jargon

| Term | Definition | References |
| :--- | :--- | :--- |
| **Raw-Inject** | The first step of the daily pipeline where source data is landed "as-is" into the `raw` schema. | `ARCHITECTURE.md:158` |
| **DQ Gate** | A data-quality check that must pass before the pipeline can proceed to the next layer or publish. | `ARCHITECTURE.md:90`, `ARCHITECTURE.md:414-415` |
| **Publish** | The process of moving refined data from PostgreSQL `marts` to Databricks Delta tables. | `ARCHITECTURE.md:166`, `src/jobs/publish_marts.py` |
| **Promote** | The atomic transaction of moving data from a transient staging table (`_stg_*`) to a permanent layer table. | `ARCHITECTURE.md:217`, `src/utils/spark_io.py` |
| **Optimistic Locking** | Using a `lock_version` column to prevent concurrent pipeline runs from updating the same watermark. | `ARCHITECTURE.md:313-315` |
| **Hermetic** | Tests or environments that have no external dependencies (e.g., no network access, mock services). | `ARCHITECTURE.md:100`, `ARCHITECTURE.md:609` |

## Connectivity Map

- **Watermarks** $\rightarrow$ connect **Source Systems** to **Raw** (`extract_watermarks`) and **Raw** to **Staging** (`etl_watermarks`).
- **DQ Gates** $\rightarrow$ sit between every layer (Raw $\rightarrow$ Staging $\rightarrow$ Analytics $\rightarrow$ Marts) and the final **Publish** step.
- **Medallion Layers** $\rightarrow$ are owned by specific tools (Spark for Raw, Stored Procedures for others) to maintain strict ownership.
- **Audit Schema** $\rightarrow$ centrally tracks all `pipeline_runs`, `table_runs`, and `watermarks` across all layers.

## Open Questions / UNVERIFIED

- **SCD2 Implementation:** `AGENTS.md:62` mentions an SCD2 load for `dim_customer`, but the `ARCHITECTURE.md` primarily highlights SCD1 in the staging layer. Verification is needed to see if SCD2 is used exclusively in the Analytics layer.
- **Great Expectations:** `AGENTS.md:7` mentions Great Expectations for validation, but `ARCHITECTURE.md` describes DQ gates as SQL suites. Need to verify if GE is used for specific validations or if it has been replaced by the SQL-based suite.
