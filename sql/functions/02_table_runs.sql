-- ============================================================
-- Script:     02_table_runs.sql
-- Purpose:    Table-level drill-down of a pipeline run: which
--             tables moved, how many rows, how long, and the
--             latest error message when one failed.
-- Function:   audit.fn_table_runs(p_pipeline_run_id, p_days, p_status)
-- Returns:    TABLE, newest table run first
-- Note:       p_days only applies when no run id is given, so
--             an old run can still be inspected in full.
-- Execute against: banking_delta        (schema: audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\functions\02_table_runs.sql
-- ============================================================

CREATE OR REPLACE FUNCTION audit.fn_table_runs(
    p_pipeline_run_id UUID DEFAULT NULL,
    p_days            INT  DEFAULT 7,
    p_status          TEXT DEFAULT NULL
)
RETURNS TABLE (
    pipeline_run_id   UUID,
    table_run_id      UUID,
    source_table      VARCHAR(255),
    target_table      VARCHAR(255),
    processing_layer  VARCHAR(255),
    operation_type    VARCHAR(255),
    status            VARCHAR(20),
    started_at        TIMESTAMPTZ,
    duration_seconds  NUMERIC,
    rows_extracted    BIGINT,
    rows_landed       BIGINT,
    error_message     TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        tr.pipeline_run_id,
        tr.table_run_id,
        tr.source_table,
        tr.target_table,
        tr.processing_layer,
        tr.operation_type,
        tr.status,
        tr.started_at,
        tr.duration_seconds,
        tr.rows_extracted,
        tr.rows_landed,
        pe.error_message
    FROM audit.table_runs AS tr
    LEFT JOIN LATERAL (
        SELECT e.error_message
        FROM audit.pipeline_errors AS e
        WHERE e.table_run_id = tr.table_run_id
        ORDER BY e.error_timestamp DESC
        LIMIT 1
    ) AS pe ON TRUE
    WHERE (p_pipeline_run_id IS NULL OR tr.pipeline_run_id = p_pipeline_run_id)
      AND (p_status IS NULL OR tr.status = p_status)
      AND (
            p_pipeline_run_id IS NOT NULL
            OR tr.started_at >= now() - make_interval(days => COALESCE(p_days, 7))
          )
    ORDER BY tr.started_at DESC;
END;
$$;
