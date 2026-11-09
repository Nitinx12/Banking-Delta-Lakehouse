-- ============================================================
-- Script:     01_pipeline_summary.sql
-- Purpose:    One row per pipeline run in the window: actual
--             table-run counts, the errors recorded against the
--             run, and the DQ failures attributed to it.
-- Function:   audit.fn_pipeline_summary(p_days, p_status)
-- Returns:    TABLE, newest run first.
--             table_runs counts every attempt row, so
--             table_runs = tables_ok + tables_failed +
--             tables_skipped (+ running while in flight).
--             Counts come from audit.table_runs, not the
--             declared rollup columns (total_tables and friends
--             are often NULL or disagree with the attempt rows).
--             dq_failed counts FAIL rows linked to the run plus
--             unlinked FAILs that happened while the run was
--             open; each unlinked failure goes to the run that
--             started latest among those open, so no failure is
--             counted twice.
-- Execute against: banking_delta        (schema: audit)
-- Idempotent: Yes (drops the previous signature first: a changed
--              return type cannot be applied with CREATE OR REPLACE)
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\functions\01_pipeline_summary.sql
-- ============================================================

DROP FUNCTION IF EXISTS audit.fn_pipeline_summary(INT, TEXT);

CREATE OR REPLACE FUNCTION audit.fn_pipeline_summary(
    p_days   INT DEFAULT 7,
    p_status TEXT DEFAULT NULL
)
RETURNS TABLE (
    pipeline_run_id   UUID,
    dag_id            VARCHAR(255),
    execution_date    TIMESTAMPTZ,
    run_type          VARCHAR(20),
    status            VARCHAR(20),
    started_at        TIMESTAMPTZ,
    ended_at          TIMESTAMPTZ,
    duration_seconds  NUMERIC,
    table_runs        BIGINT,
    tables_ok         BIGINT,
    tables_failed     BIGINT,
    tables_skipped    BIGINT,
    error_count       BIGINT,
    dq_failed         BIGINT
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
        COALESCE(tr.n, 0),
        COALESCE(tr.ok, 0),
        COALESCE(tr.failed, 0),
        COALESCE(tr.skipped, 0),
        COALESCE(er.n, 0),
        COALESCE(dq.n, 0)
    FROM audit.pipeline_runs AS pr
    LEFT JOIN (
        SELECT
            t.pipeline_run_id,
            COUNT(*) AS n,
            COUNT(*) FILTER (WHERE t.status = 'SUCCESS') AS ok,
            COUNT(*) FILTER (WHERE t.status = 'FAILED') AS failed,
            COUNT(*) FILTER (WHERE t.status = 'SKIPPED') AS skipped
        FROM audit.table_runs AS t
        GROUP BY t.pipeline_run_id
    ) AS tr ON tr.pipeline_run_id = pr.pipeline_run_id
    LEFT JOIN (
        SELECT
            e.pipeline_run_id,
            COUNT(*) AS n
        FROM audit.pipeline_errors AS e
        WHERE e.pipeline_run_id IS NOT NULL
        GROUP BY e.pipeline_run_id
    ) AS er ON er.pipeline_run_id = pr.pipeline_run_id
    LEFT JOIN LATERAL (
        SELECT COUNT(*) AS n
        FROM audit.dq_run AS q
        WHERE q.status = 'FAIL'
          AND (
                q.pipeline_run_id = pr.pipeline_run_id
                OR (
                    q.pipeline_run_id IS NULL
                    AND q.started_at >= pr.started_at
                    AND q.started_at <= COALESCE(pr.ended_at, now())
                    AND NOT EXISTS (
                        SELECT 1
                        FROM audit.pipeline_runs AS pr2
                        WHERE pr2.started_at > pr.started_at
                          AND pr2.started_at <= q.started_at
                          AND q.started_at <= COALESCE(pr2.ended_at, now())
                    )
                )
          )
    ) AS dq ON TRUE
    WHERE pr.started_at >= now() - make_interval(days => COALESCE(p_days, 7))
      AND (p_status IS NULL OR pr.status = p_status)
    ORDER BY pr.started_at DESC;
END;
$$;
