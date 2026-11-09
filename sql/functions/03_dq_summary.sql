-- ============================================================
-- Script:     03_dq_summary.sql
-- Purpose:    One row per DQ script in the window with pass /
--             fail counts, total violations and the latest
--             verdict, so the health of every gate is visible
--             in a single query.
-- Function:   audit.fn_dq_summary(p_days, p_layer)
-- Returns:    TABLE, layer then script name
-- Execute against: banking_delta        (schema: audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\functions\03_dq_summary.sql
-- ============================================================

CREATE OR REPLACE FUNCTION audit.fn_dq_summary(
    p_days  INT DEFAULT 7,
    p_layer TEXT DEFAULT NULL
)
RETURNS TABLE (
    layer           TEXT,
    script_name     TEXT,
    runs            BIGINT,
    passed          BIGINT,
    failed          BIGINT,
    violations      BIGINT,
    last_status     TEXT,
    last_checked_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        q.layer,
        q.script_name,
        COUNT(*),
        COUNT(*) FILTER (WHERE q.status = 'PASS'),
        COUNT(*) FILTER (WHERE q.status = 'FAIL'),
        COALESCE(SUM(q.violation_count), 0),
        (ARRAY_AGG(q.status ORDER BY q.started_at DESC))[1],
        MAX(q.started_at)
    FROM audit.dq_run AS q
    WHERE q.started_at >= now() - make_interval(days => COALESCE(p_days, 7))
      AND (p_layer IS NULL OR q.layer = p_layer)
    GROUP BY q.layer, q.script_name
    ORDER BY q.layer, q.script_name;
END;
$$;
