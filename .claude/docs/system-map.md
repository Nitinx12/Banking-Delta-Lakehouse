# System Map — Banking-Delta-Lakehouse

## Dependency & Flow Overview

```mermaid
graph TD
    subgraph Sources
        MySQL[(MySQL)]
        Mongo[(MongoDB)]
        DBX_Src[(Databricks Delta)]
    end

    subgraph Orchestration
        Airflow[Airflow DAG] --> Main[main.py / scripts/]
    end

    subgraph PostgreSQL_Warehouse
        subgraph Raw_Layer
            R_Stg[raw._stg_*] --> R_Promote[raw.*]
        end
        subgraph Staging_Layer
            R_Promote --> S_Load[staging.sp_load_*]
        end
        subgraph Analytics_Layer
            S_Load --> A_Load[analytics.sp_load_*]
        end
        subgraph Marts_Layer
            A_Load --> M_Load[marts.sp_load_*]
        end
        subgraph Audit_System
            Audit[(audit schema)]
            Audit -.->|Watermarks| R_Promote
            Audit -.->|Watermarks| S_Load
            Audit -.->|Run Tracking| Main
        end
    end

    subgraph DQ_Gates
        DQ_R[tests/data-quality/raw]
        DQ_S[tests/data-quality/staging]
        DQ_A[tests/data-quality/analytics]
        DQ_M[tests/data-quality/marts]
    end

    subgraph Consumption
        DBX_Target[(Databricks Marts)]
        Dashboard[Streamlit Dashboard]
        R_Analysis[R Analysis/Quarto]
    end

    %% Flow
    MySQL & Mongo & DBX_Src -->|src/jobs/extract_*.py| R_Stg
    R_Promote --> DQ_R --> S_Load
    S_Load --> DQ_S --> A_Load
    A_Load --> DQ_A --> M_Load
    M_Load --> DQ_M -->|src/jobs/publish_marts.py| DBX_Target
    DBX_Target --> Dashboard
    DBX_Target --> R_Analysis

    %% Gates
    DQ_R -.->|Block| S_Load
    DQ_S -.->|Block| A_Load
    DQ_A -.->|Block| M_Load
    DQ_M -.->|Block| DBX_Target
```

## End-to-End Traces

### 1. Daily Data Landing (Source $\rightarrow$ Raw)
**User/Scheduler** $\rightarrow$ `Airflow DAG` $\rightarrow$ `main.py` $\rightarrow$ `scripts/run_jobs.py` $\rightarrow$ `src/jobs/extract_mysql.py` $\rightarrow$ `src/utils/spark_io.py` $\rightarrow$ `raw._stg_customers` $\rightarrow$ `raw.customers` $\rightarrow$ `audit.extract_watermarks`.

### 2. Gated Transformation (Raw $\rightarrow$ Marts)
`main.py` $\rightarrow$ `scripts/run_raw_tests.py` $\rightarrow$ `tests/data-quality/raw/*.sql` $\rightarrow$ `audit.dq_run` $\rightarrow$ (Pass) $\rightarrow$ `staging.sp_load_all()` $\rightarrow$ `staging.customers` $\rightarrow$ `analytics.dim_customer` $\rightarrow$ `marts.mart_customer_360`.

### 3. Publishing to Lakehouse (Warehouse $\rightarrow$ Databricks)
`main.py` $\rightarrow$ `src/jobs/publish_marts.py` $\rightarrow$ `psycopg2` (Read `marts.*`) $\rightarrow$ `pyarrow` (Local Parquet) $\rightarrow$ `databricks-sdk` (Upload to Volume) $\rightarrow$ `Databricks SQL` (INSERT OVERWRITE) $\rightarrow$ `Databricks Delta Table`.

### 4. Business Insight (Databricks $\rightarrow$ UI)
**Executive User** $\rightarrow$ `dashboard/app.py` $\rightarrow$ `dashboard/helpers/marts.py` $\rightarrow$ `databricks-sql-connector` $\rightarrow$ `SELECT` from `marts.mart_customer_360` $\rightarrow$ `Plotly Chart`.
