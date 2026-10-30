-- ============================================================
-- Script:   00_master_load.sql
-- Purpose:  Master procedure - runs all mart refreshes in order
-- Database: banking_delta
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1
--      -f .\sql\marts\00_master_load.sql
--
-- Usage:
--   CALL marts.sp_load_all();                       -- refresh every mart
--   CALL marts.sp_load_all(p_force_full => TRUE);   -- always full refresh
--   CALL marts.sp_load_all(p_pipeline_run_id => ...);
--
-- To add a new mart: add one CALL line in the marked place below.
-- ============================================================

-- The DROP retires the pre-audit (boolean) signature; a no-op on a fresh database.
DROP PROCEDURE IF EXISTS marts.sp_load_all(boolean);

CREATE OR REPLACE PROCEDURE marts.sp_load_all(
    IN p_force_full BOOLEAN DEFAULT FALSE,
    IN p_pipeline_run_id UUID DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- One batch label shared by every refresh in this run
    v_batch_id        TEXT := 'run_' || to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS');
    v_pipeline_run_id UUID := COALESCE(p_pipeline_run_id, gen_random_uuid());
BEGIN
    p_force_full := COALESCE(p_force_full, FALSE);

    RAISE NOTICE '=== Marts load started | batch=% | force_full=% ===', v_batch_id, p_force_full;

    -- 1) customer 360 (needs all dims + facts)
    CALL marts.sp_load_mart_customer_360(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 2) branch performance (needs dims + loan payments + transactions)
    CALL marts.sp_load_mart_branch_performance(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 3) monthly transactions (needs fact_transactions + dims)
    CALL marts.sp_load_mart_monthly_transactions(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 4) loan portfolio (needs dim_loan + fact_loan_payments)
    CALL marts.sp_load_mart_loan_portfolio(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 5) card fraud (needs fact_card_transactions + dim_card)
    CALL marts.sp_load_mart_card_fraud(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 6) support performance (needs fact_support_tickets + dim_customer)
    CALL marts.sp_load_mart_support_performance(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 7) monthly KPI (needs all dims + facts)
    CALL marts.sp_load_mart_kpi_monthly(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 8) loan vintage (needs dim_loan + fact_loan_payments)
    CALL marts.sp_load_mart_loan_vintage(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- >>> ADD NEW MARTS HERE (one CALL per mart) <<<

    RAISE NOTICE '=== Marts load finished | batch=% ===', v_batch_id;
END;
$$;
