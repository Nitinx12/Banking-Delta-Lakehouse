-- ============================================================
-- Script:     06_extract_watermarks.sql
-- Purpose:    Source->raw extract progress, one row per configured
--             table. Separate from audit.etl_watermarks, which the
--             staging procedures use for raw->staging progress on the
--             same config_id — the two layers must not share a value.
-- Execute against: banking_delta
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\scripts\06_extract_watermarks.sql
-- ============================================================

DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS audit.extract_watermarks (
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
