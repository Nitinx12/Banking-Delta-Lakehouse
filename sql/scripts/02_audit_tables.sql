-- ============================================================
-- Script: 02_audit_tables.sql
-- Purpose: Initialize centralized pipeline audit tables.
-- Database: banking_delta
-- Schema: audit
-- Idempotent: Yes
-- Run: psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f .\sql\scripts\02_audit_tables.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS audit;

-- Source registry
CREATE TABLE IF NOT EXISTS audit.source_registry (
    source_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_type VARCHAR(20) NOT NULL
    CHECK (source_type IN ('mongodb', 'mysql', 'databricks')),
    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Source table registry
CREATE TABLE IF NOT EXISTS audit.source_tables (
    config_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_id BIGINT NOT NULL
    REFERENCES audit.source_registry (source_id),
    source_schema VARCHAR(255),
    source_table VARCHAR(255),
    target_schema VARCHAR(255),
    target_table VARCHAR(255),
    business_key VARCHAR(255),
    load_strategy VARCHAR(20) NOT NULL DEFAULT 'full'
    CHECK (load_strategy IN ('full', 'incremental')),
    incremental_column VARCHAR(255),
    watermark_strategy VARCHAR(255),
    batch_size INTEGER,
    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (source_id, source_schema, source_table)
);

-- Pipeline run history
CREATE TABLE IF NOT EXISTS audit.pipeline_runs (
    pipeline_run_id UUID PRIMARY KEY,
    dag_id VARCHAR(255),
    dag_run_id VARCHAR(255),
    execution_date TIMESTAMPTZ,
    run_type VARCHAR(20),
    trigger_type VARCHAR(20),
    status VARCHAR(20) NOT NULL DEFAULT 'RUNNING'
    CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    total_tables INTEGER,
    successful_tables INTEGER,
    failed_tables INTEGER,
    skipped_tables INTEGER,
    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMPTZ,
    duration_seconds NUMERIC
);

-- ETL watermarks
CREATE TABLE IF NOT EXISTS audit.etl_watermarks (
    watermark_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_id BIGINT NOT NULL,
    config_id BIGINT NOT NULL,
    watermark_column VARCHAR(255),
    watermark_strategy VARCHAR(255),
    last_watermark_value TEXT,
    previous_watermark_value TEXT,
    current_batch_start TEXT,
    current_batch_end TEXT,
    last_success_pipeline_run UUID,
    last_success_table_run UUID,
    last_success_at TIMESTAMPTZ,
    lock_version BIGINT NOT NULL DEFAULT 0,
    UNIQUE (source_id, config_id)
);

-- Table runs
CREATE TABLE IF NOT EXISTS audit.table_runs (
    table_run_id UUID PRIMARY KEY,
    pipeline_run_id UUID NOT NULL
    REFERENCES audit.pipeline_runs (pipeline_run_id),
    config_id BIGINT,
    source_id BIGINT,
    source_table VARCHAR(255),
    target_table VARCHAR(255),
    processing_layer VARCHAR(255),
    operation_type VARCHAR(255),
    attempt_number INTEGER,
    status VARCHAR(20) NOT NULL DEFAULT 'RUNNING'
    CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED', 'SKIPPED')),
    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMPTZ,
    duration_seconds NUMERIC,
    airflow_task_id VARCHAR(255),
    airflow_try_number INTEGER,
    execution_metadata JSONB,
    rows_extracted BIGINT,
    rows_landed BIGINT,
    watermark_start TEXT,
    watermark_end TEXT,
    error_id BIGINT
);

-- Pipeline errors
CREATE TABLE IF NOT EXISTS audit.pipeline_errors (
    error_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pipeline_run_id UUID,
    table_run_id UUID,
    source_table VARCHAR(255),
    target_table VARCHAR(255),
    processing_layer VARCHAR(255),
    error_category VARCHAR(255),
    severity VARCHAR(255),
    error_message TEXT,
    error_details JSONB,
    error_timestamp TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    retry_attempt INTEGER,
    is_recoverable BOOLEAN,
    resolution_status VARCHAR(255)
);

-- Data quality results
CREATE TABLE IF NOT EXISTS audit.data_quality_results (
    dq_result_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id BIGINT,
    source_table_id BIGINT,
    check_name VARCHAR(255) NOT NULL,
    status VARCHAR(20) NOT NULL
    CHECK (status IN ('passed', 'failed', 'warning')),
    records_checked BIGINT NOT NULL DEFAULT 0,
    records_failed BIGINT NOT NULL DEFAULT 0,
    details JSONB NOT NULL DEFAULT '{}'::JSONB,
    checked_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_pipeline_runs_status_started
ON audit.pipeline_runs (status, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_table_runs_pipeline_run_id
ON audit.table_runs (pipeline_run_id);

CREATE INDEX IF NOT EXISTS idx_pipeline_errors_pipeline_run_id
ON audit.pipeline_errors (pipeline_run_id);

