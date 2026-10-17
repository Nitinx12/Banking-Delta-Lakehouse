-- ============================================================
-- Script:     04_dq_audit_tables.sql
-- Purpose:    Audit tables for the data-quality test gate.
--             Every DQ test procedure writes one dq_run row plus
--             one dq_violation row per violation, so pass/fail
--             history is queryable and the scheduler can read
--             audit.v_dq_latest instead of scraping output.
-- Execute against: banking_delta        (schema: audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\scripts\04_dq_audit_tables.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE IF NOT EXISTS audit.dq_run (
    run_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    layer            TEXT        NOT NULL DEFAULT 'raw',
    script_name      TEXT        NOT NULL,
    started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at      TIMESTAMPTZ,
    status           TEXT,
    violation_count  INT
);

CREATE INDEX IF NOT EXISTS ix_dq_run_lookup
    ON audit.dq_run (script_name, started_at DESC);

CREATE TABLE IF NOT EXISTS audit.dq_violation (
    violation_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        BIGINT NOT NULL REFERENCES audit.dq_run(run_id),
    message       TEXT   NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_dq_violation_run ON audit.dq_violation(run_id);

-- latest result per script
CREATE OR REPLACE VIEW audit.v_dq_latest AS
SELECT DISTINCT ON (layer, script_name)
       layer, script_name, run_id, started_at, status, violation_count
FROM audit.dq_run
ORDER BY layer, script_name, started_at DESC;
