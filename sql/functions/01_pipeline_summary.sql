-- ============================================================
-- Script:     01_pipeline_summary.sql
-- Purpose:    One row per pipeline run in the window, with the
--             table-run, error and DQ rollups joined in, so a
--             run can be judged without hand-joining audit
--             tables.
-- Function:   audit.fn_pipeline_summary(p_days, p_status)
-- Returns:    TABLE, newest run first
-- Execute against: banking_delta        (schema: audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\functions\01_pipeline_summary.sql
-- ============================================================

CREATE OR REPLACE FUNCTION audit.fn_pipeline_summary(
    p_days   INT DEFAULT 7,
    p_status TEXT DEFAULT NULL
)
RETURNS TABLE (
    pipeline_run_id    UUID,
    dag_id             VARCHAR(255),
    execution_date     TIMESTAMPTZ,
    run_type           VARCHAR(20),
    status             VARCHAR(20),
    started_at         TIMESTAMPTZ,
    ended_at           TIMESTAMPTZ,
    duration_seconds   NUMERIC,
    total_tables       INTEGER,
    successful_tables  INTEGER,
    failed_tables      INTEGER,
    table_runs         BIGINT,
    error_count        BIGINT,
    dq_failed          BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        pr.pipeline_run_id,
        pr.dag_id,
        pr.execution_date,
        pr.run_type,
        pr.status,
        pr.started_at,
        pr.ended_at,
        pr.duration_seconds,
        pr.total_tables,
        pr.successful_tables,
        pr.failed_tables,
        COALESCE(tr.runs, 0),
        COALESCE(er.runs, 0),
        COALESCE(dq.runs, 0)
    FROM audit.pipeline_runs AS pr
    LEFT JOIN (
        SELECT
            t.pipeline_run_id,
            COUNT(*) AS runs
        FROM audit.table_runs AS t
        GROUP BY t.pipeline_run_id
    ) AS tr ON tr.pipeline_run_id = pr.pipeline_run_id
    LEFT JOIN (
        SELECT
            e.pipeline_run_id,
            COUNT(*) AS runs
        FROM audit.pipeline_errors AS e
        WHERE e.pipeline_run_id IS NOT NULL
        GROUP BY e.pipeline_run_id
    ) AS er ON er.pipeline_run_id = pr.pipeline_run_id
    LEFT JOIN (
        SELECT
            q.pipeline_run_id,
            COUNT(*) AS runs
        FROM audit.dq_run AS q
        WHERE q.pipeline_run_id IS NOT NULL
          AND q.status = 'FAIL'
        GROUP BY q.pipeline_run_id
    ) AS dq ON dq.pipeline_run_id = pr.pipeline_run_id
    WHERE pr.started_at >= now() - make_interval(days => COALESCE(p_days, 7))
      AND (p_status IS NULL OR pr.status = p_status)
    ORDER BY pr.started_at DESC;
END;
$$;
