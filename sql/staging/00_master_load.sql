-- ============================================================
-- Script:   00_master_load.sql
-- Purpose:  Master procedure - runs all staging loads in order
-- Database: banking_delta
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\staging\00_master_load.sql
--
-- Usage:
--   CALL staging.sp_load_all();                       -- normal incremental run
--   CALL staging.sp_load_all(p_force_full => TRUE);   -- full reload of everything
--
-- To add a new load: add one CALL line in the marked place below.
-- Put parents before children (e.g. customers before accounts).
-- ============================================================

CREATE OR REPLACE PROCEDURE staging.sp_load_all(
    IN p_force_full BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- One batch label shared by every load in this run
    v_batch_id TEXT := 'run_' || to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS');
    v_pipeline_run_id   UUID    := gen_random_uuid();
BEGIN
    p_force_full := COALESCE(p_force_full, FALSE);

    RAISE NOTICE '=== Staging load started | batch=% | force_full=% ===', v_batch_id, p_force_full;

    -- 1) customers (parent)
    CALL staging.sp_load_customers_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 2) branches (parent)
    CALL staging.sp_load_branches_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 3) employees (needs branches)
    CALL staging.sp_load_employees_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 4) accounts (needs customers + branches)
    CALL staging.sp_load_accounts_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 5) cards (needs customers + accounts)
    CALL staging.sp_load_cards_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 6) card_transactions (needs cards)
    CALL staging.sp_load_card_transactions_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 7) loans (needs customers + branches)
    CALL staging.sp_load_loans_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 8) loan_payments (needs loans)
    CALL staging.sp_load_loan_payments_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 9) transactions (needs accounts)
    CALL staging.sp_load_transactions_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 10) support tickets (needs customers)
    CALL staging.sp_load_support_tickets_scd1(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- >>> ADD NEW LOADS HERE (one CALL per table, parents first) <<<

    RAISE NOTICE '=== Staging load finished | batch=% ===', v_batch_id;
END;
$$;
