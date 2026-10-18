-- ============================================================
-- Script:   00_master_load.sql
-- Purpose:  Master procedure - runs analytics loads in dependency order.
-- Database: banking_delta
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\00_master_load.sql
--
-- Usage:
--   CALL analytics.sp_load_all();                       -- normal incremental run
--   CALL analytics.sp_load_all(p_force_full => TRUE);   -- full reload of everything
-- ============================================================
CREATE OR REPLACE PROCEDURE analytics.sp_load_all(
    IN p_force_full BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch_id        TEXT := 'run_' || to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS');
    v_pipeline_run_id UUID := gen_random_uuid();
BEGIN
    p_force_full := COALESCE(p_force_full, FALSE);

    RAISE NOTICE '=== Analytics load started | batch=% | force_full=% ===',
        v_batch_id, p_force_full;

    -- 1) customer (parent)
    CALL analytics.sp_load_dim_customer(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );
    -- 2) branch (parent)
    CALL analytics.sp_load_dim_branch(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );
    -- 3) employee (needs branch)
    CALL analytics.sp_load_dim_employee(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );
    -- 4) account (needs customer)
    CALL analytics.sp_load_dim_account(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );
    -- 5) card (needs customer and account)
    CALL analytics.sp_load_dim_card(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );
    -- 6) loan (needs customer and branch)
    CALL analytics.sp_load_dim_loan(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );
    -- 7) transaction profile (parent for transactions)
    CALL analytics.sp_load_dim_txn_profile(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );

    -- 8) card transactions (needs card)
    CALL analytics.sp_load_fact_card_transactions(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );
    -- 9) loan payments (needs loan)
    CALL analytics.sp_load_fact_loan_payments(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );
    -- 10) transactions (needs account and transaction profile)
    CALL analytics.sp_load_fact_transactions(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );
    -- 11) support tickets (needs customer)
    CALL analytics.sp_load_fact_support_tickets(
        p_pipeline_run_id => v_pipeline_run_id,
        p_source_batch_id => v_batch_id,
        p_force_full => p_force_full
    );

    RAISE NOTICE '=== Analytics load finished | batch=% ===', v_batch_id;
END;
$$;
