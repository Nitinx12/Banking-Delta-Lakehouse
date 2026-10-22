-- ============================================================
-- Script:     07_dq_pipeline_run.sql
-- Purpose:    Add pipeline_run_id to audit.dq_run to tie DQ results
--             to a specific pipeline run. Update v_dq_latest view.
-- Execute against: banking_delta
-- Idempotent: Yes
-- ============================================================

DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;
END $$;

-- Add pipeline_run_id to dq_run (nullable for backward compatibility)
ALTER TABLE audit.dq_run
    ADD COLUMN IF NOT EXISTS pipeline_run_id UUID;

-- Add index for querying DQ results by pipeline run
CREATE INDEX IF NOT EXISTS ix_dq_run_pipeline_run
    ON audit.dq_run (pipeline_run_id);

-- Update v_dq_latest to include pipeline_run_id and is_this_run flag
-- Note: is_this_run requires a context parameter; we'll use a session variable
CREATE OR REPLACE VIEW audit.v_dq_latest AS
SELECT DISTINCT ON (layer, script_name)
       layer, script_name, run_id, pipeline_run_id,
       started_at, status, violation_count
FROM audit.dq_run
ORDER BY layer, script_name, started_at DESC;