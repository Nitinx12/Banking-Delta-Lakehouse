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
BEGIN
    p_force_full := COALESCE(p_force_full, FALSE);

    RAISE NOTICE '=== Staging load started | batch=% | force_full=% ===', v_batch_id, p_force_full;

    -- 1) customers (parent)
    CALL staging.sp_load_customers_scd1(
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 2) accounts (needs customers)
    CALL staging.sp_load_accounts_scd1(
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    -- 3) branches (needs customers, accounts)
    CALL staging.sp_load_branches_scd1(
        p_source_batch_id => v_batch_id,
        p_force_full      => p_force_full
    );

    RAISE NOTICE '=== Staging load finished | batch=% ===', v_batch_id;
END;
$$;
