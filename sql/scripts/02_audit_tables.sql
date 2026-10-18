-- ============================================================
-- Script:     02_audit_tables.sql
-- Purpose:    Initialize centralized pipeline audit tables.
-- Execute against: banking_delta        (schema: audit)
-- Idempotent: Yes (for a fresh audit schema created by THIS version)
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\scripts\02_audit_tables.sql
--
-- If you ran the OLD version of this script (no data in it yet), first run:
--     DROP SCHEMA audit CASCADE;
-- then 01_init_schemas.sql, then this script.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('audit.source_registry') IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'audit'
              AND table_name   = 'source_registry'
              AND column_name  = 'source_name'
       )
    THEN
        RAISE EXCEPTION 'Old audit schema detected. Run: DROP SCHEMA audit CASCADE; then re-run 01 and 02.';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS audit;

-- Shared trigger: keep updated_at honest. Column comes from the trigger
-- argument so staging/analytics tables can pass 'row_updated_at'; audit
-- tables call it without an argument and keep 'updated_at'.
CREATE OR REPLACE FUNCTION audit.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW := jsonb_populate_record(NEW, jsonb_build_object(
        COALESCE(TG_ARGV[0], 'updated_at'), clock_timestamp()));
    RETURN NEW;
END $$;

-- ------------------------------------------------------------
-- Source registry: one row per source system
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.source_registry (
    source_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_name VARCHAR(100) NOT NULL UNIQUE,
    source_type VARCHAR(20)  NOT NULL
        CHECK (source_type IN ('mongodb', 'mysql', 'databricks')),
    is_enabled  BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ------------------------------------------------------------
-- Source table registry: one row per table/collection to extract
-- (source_schema = MySQL database / Mongo database / Databricks schema)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.source_tables (
    config_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_id          BIGINT       NOT NULL REFERENCES audit.source_registry (source_id),
    source_schema      VARCHAR(255) NOT NULL,
    source_table       VARCHAR(255) NOT NULL,
    target_schema      VARCHAR(255) NOT NULL DEFAULT 'raw',
    target_table       VARCHAR(255) NOT NULL,
    business_key       VARCHAR(255),
    load_strategy      VARCHAR(20)  NOT NULL DEFAULT 'full'
        CHECK (load_strategy IN ('full', 'incremental')),
    incremental_column VARCHAR(255),
    watermark_strategy VARCHAR(20)
        CHECK (watermark_strategy IN ('timestamp', 'numeric', 'objectid')),
    -- Spark tuning (per table)
    partition_column   VARCHAR(255),                       -- numeric/date column for parallel JDBC reads
    num_partitions     INTEGER NOT NULL DEFAULT 4  CHECK (num_partitions BETWEEN 1 AND 64),
    fetch_size         INTEGER NOT NULL DEFAULT 10000 CHECK (fetch_size > 0),
    batch_size         INTEGER NOT NULL DEFAULT 20000 CHECK (batch_size > 0),  -- JDBC write batch
    is_enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_incremental_needs_column CHECK (
        load_strategy = 'full'
        OR (incremental_column IS NOT NULL AND watermark_strategy IS NOT NULL)
    ),
    CONSTRAINT chk_target_names CHECK (
        target_schema ~ '^[a-z_][a-z0-9_]*$' AND target_table ~ '^[a-z_][a-z0-9_]*$'
    ),
    UNIQUE (source_id, source_schema, source_table),
    UNIQUE (target_schema, target_table)
);

-- ------------------------------------------------------------
-- Pipeline run history (one per Airflow DAG run)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.pipeline_runs (
    pipeline_run_id   UUID PRIMARY KEY,
    dag_id            VARCHAR(255),
    dag_run_id        VARCHAR(255),
    execution_date    TIMESTAMPTZ,
    run_type          VARCHAR(20),
    trigger_type      VARCHAR(20),
    status            VARCHAR(20) NOT NULL DEFAULT 'RUNNING'
        CHECK (status IN ('RUNNING', 'SUCCESS', 'PARTIAL', 'FAILED')),
    total_tables      INTEGER,
    successful_tables INTEGER,
    failed_tables     INTEGER,
    skipped_tables    INTEGER,
    started_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ended_at          TIMESTAMPTZ,
    duration_seconds  NUMERIC
);

-- One pipeline run per Airflow DAG run, so parallel per-source tasks share it.
CREATE UNIQUE INDEX IF NOT EXISTS uq_pipeline_runs_dag_run
ON audit.pipeline_runs (dag_id, dag_run_id)
WHERE dag_run_id IS NOT NULL;

-- ------------------------------------------------------------
-- ETL watermarks: one row per configured table
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.etl_watermarks (
    watermark_id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_id                 BIGINT NOT NULL REFERENCES audit.source_registry (source_id),
    config_id                 BIGINT NOT NULL UNIQUE REFERENCES audit.source_tables (config_id),
    watermark_column          VARCHAR(255),
    watermark_strategy        VARCHAR(20),
    last_watermark_value      TEXT,
    previous_watermark_value  TEXT,
    current_batch_start       TEXT,
    current_batch_end         TEXT,
    last_success_pipeline_run UUID,
    last_success_table_run    UUID,
    last_success_at           TIMESTAMPTZ,
    lock_version              BIGINT NOT NULL DEFAULT 0,   -- optimistic lock
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ------------------------------------------------------------
-- Table runs (one per table per attempt)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.table_runs (
    table_run_id       UUID PRIMARY KEY,
    pipeline_run_id    UUID NOT NULL REFERENCES audit.pipeline_runs (pipeline_run_id),
    config_id          BIGINT REFERENCES audit.source_tables (config_id),
    source_id          BIGINT REFERENCES audit.source_registry (source_id),
    source_table       VARCHAR(255),
    target_table       VARCHAR(255),
    processing_layer   VARCHAR(255),
    operation_type     VARCHAR(255),
    attempt_number     INTEGER,
    status             VARCHAR(20) NOT NULL DEFAULT 'RUNNING'
        CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED', 'SKIPPED')),
    started_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ended_at           TIMESTAMPTZ,
    duration_seconds   NUMERIC,
    airflow_task_id    VARCHAR(255),
    airflow_try_number INTEGER,
    execution_metadata JSONB,
    rows_extracted     BIGINT,
    rows_landed        BIGINT,
    watermark_start    TEXT,
    watermark_end      TEXT,
    error_id           BIGINT
);

-- ------------------------------------------------------------
-- Pipeline errors
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.pipeline_errors (
    error_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pipeline_run_id  UUID,
    table_run_id     UUID,
    source_table     VARCHAR(255),
    target_table     VARCHAR(255),
    processing_layer VARCHAR(255),
    error_category   VARCHAR(255),
    severity         VARCHAR(255),
    error_message    TEXT,
    error_details    JSONB,
    error_timestamp  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    retry_attempt    INTEGER,
    is_recoverable   BOOLEAN,
    resolution_status VARCHAR(255)
);

-- ------------------------------------------------------------
-- Data quality results (ids now match the UUID/config_id model)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.data_quality_results (
    dq_result_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pipeline_run_id UUID,
    table_run_id    UUID,
    config_id       BIGINT REFERENCES audit.source_tables (config_id),
    check_name      VARCHAR(255) NOT NULL,
    status          VARCHAR(20)  NOT NULL
        CHECK (status IN ('PASSED', 'FAILED', 'WARNING')),
    records_checked BIGINT NOT NULL DEFAULT 0,
    records_failed  BIGINT NOT NULL DEFAULT 0,
    details         JSONB  NOT NULL DEFAULT '{}'::JSONB,
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Indexes -------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_status_started
    ON audit.pipeline_runs (status, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_table_runs_pipeline_run_id
    ON audit.table_runs (pipeline_run_id);

CREATE INDEX IF NOT EXISTS idx_table_runs_config_started
    ON audit.table_runs (config_id, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_table_runs_running
    ON audit.table_runs (started_at) WHERE status = 'RUNNING';

CREATE INDEX IF NOT EXISTS idx_pipeline_errors_pipeline_run_id
    ON audit.pipeline_errors (pipeline_run_id);

CREATE INDEX IF NOT EXISTS idx_pipeline_errors_table_run_id
    ON audit.pipeline_errors (table_run_id);

CREATE INDEX IF NOT EXISTS idx_dq_results_table_run_id
    ON audit.data_quality_results (table_run_id);

-- updated_at triggers -------------------------------------------
DROP TRIGGER IF EXISTS trg_source_registry_updated_at ON audit.source_registry;
CREATE TRIGGER trg_source_registry_updated_at
    BEFORE UPDATE ON audit.source_registry
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

DROP TRIGGER IF EXISTS trg_source_tables_updated_at ON audit.source_tables;
CREATE TRIGGER trg_source_tables_updated_at
    BEFORE UPDATE ON audit.source_tables
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

-- etl_watermarks sets updated_at itself in the UPDATE statements (utils/audit.py).

-- Verify.
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'audit' AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- Expected: 7 rows (data_quality_results, etl_watermarks, pipeline_errors,
--           pipeline_runs, source_registry, source_tables, table_runs).
