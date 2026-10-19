-- ============================================================
-- Script:   02_mart_branch_performance.sql
-- Purpose:  Full refresh: analytics dims/facts -> marts.mart_branch_performance
-- Database: banking_delta (schemas: analytics, marts, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1
--      -f .\sql\marts\02_mart_branch_performance.sql
-- Depends on: 02_dim_account, 03_dim_branch, 04_dim_employee, 07_dim_loan,
--             08_fact_loan_payments, 10_fact_transactions
--
-- Grain:   one row per branch.
-- Measure: customers, accounts, staff, loans, repayment, transaction volume.
--
-- Notes:
--   * Marts are aggregates of analytics: they are rebuilt in full on every run
--     (DROP + CTAS inside the procedure), so there is no source watermark.
--   * p_force_full is accepted for signature parity with the other layers;
--     a mart refresh is always full.
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('analytics.dim_account') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_account not found - run analytics/02_dim_account.sql first.';
    END IF;

    IF to_regclass('analytics.dim_branch') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_branch not found - run analytics/03_dim_branch.sql first.';
    END IF;

    IF to_regclass('analytics.dim_employee') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_employee not found - run analytics/04_dim_employee.sql first.';
    END IF;

    IF to_regclass('analytics.dim_loan') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_loan not found - run analytics/07_dim_loan.sql first.';
    END IF;

    IF to_regclass('analytics.fact_loan_payments') IS NULL THEN
        RAISE EXCEPTION 'analytics.fact_loan_payments not found - run analytics/08_fact_loan_payments.sql first.';
    END IF;

    IF to_regclass('analytics.fact_transactions') IS NULL THEN
        RAISE EXCEPTION 'analytics.fact_transactions not found - run analytics/10_fact_transactions.sql first.';
    END IF;

    IF to_regclass('audit.table_runs') IS NULL THEN
        RAISE EXCEPTION 'audit.table_runs missing - run 02_audit_tables.sql first.';
    END IF;

    IF to_regclass('audit.pipeline_errors') IS NULL THEN
        RAISE EXCEPTION 'audit.pipeline_errors missing - run 02_audit_tables.sql first.';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS marts;

-- ------------------------------------------------------------
-- Load procedure (full refresh)
-- Usage: CALL marts.sp_load_mart_branch_performance();
-- All params optional. No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS marts.sp_load_mart_branch_performance(
    UUID, TEXT, BOOLEAN, UUID
);

CREATE OR REPLACE PROCEDURE marts.sp_load_mart_branch_performance(
    IN p_table_run_id UUID DEFAULT NULL,
    IN p_source_batch_id TEXT DEFAULT NULL,
    IN p_force_full BOOLEAN DEFAULT FALSE,
    IN p_pipeline_run_id UUID DEFAULT NULL
)
LANGUAGE plpgsql
SET work_mem = '256MB'
AS $$
DECLARE
    v_started_at         TIMESTAMPTZ := clock_timestamp();
    v_rows_previous      BIGINT := 0;
    v_rows_built         BIGINT := 0;
    v_watermark_advanced TEXT;
    -- Audit seeding (manual runs without an orchestrator)
    v_pipeline_run_id    UUID    := COALESCE(p_pipeline_run_id, gen_random_uuid());
    v_audit_seeded       BOOLEAN := FALSE;
BEGIN
    -- Defaults for manual runs
    p_table_run_id    := COALESCE(p_table_run_id, gen_random_uuid());
    p_source_batch_id := COALESCE(p_source_batch_id,
                                  'manual_' || to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS'));
    p_force_full      := COALESCE(p_force_full, FALSE);

    -- Seed audit rows so SUCCESS / FAILED land even on manual CALLs (no orchestrator)
    IF NOT EXISTS (SELECT 1 FROM audit.table_runs WHERE table_run_id = p_table_run_id) THEN
        v_audit_seeded := TRUE;

        INSERT INTO audit.pipeline_runs (
            pipeline_run_id,
            dag_id,
            run_type,
            trigger_type,
            status
        )
        VALUES (v_pipeline_run_id, 'manual_sql', 'MANUAL', 'manual', 'RUNNING')
        ON CONFLICT (pipeline_run_id) DO NOTHING;

        INSERT INTO audit.table_runs (
            table_run_id,
            pipeline_run_id,
            source_table,
            target_table,
            processing_layer,
            operation_type,
            status
        )
        VALUES (
            p_table_run_id, v_pipeline_run_id,
            'analytics (dims + facts)', 'marts.mart_branch_performance',
            'marts', 'REFRESH', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Size of the previous refresh, for the audit summary
    IF to_regclass('marts.mart_branch_performance') IS NOT NULL THEN
        SELECT count(*) INTO v_rows_previous FROM marts.mart_branch_performance;
    END IF;

    -- Full refresh: rebuild the aggregate
    DROP TABLE IF EXISTS marts.mart_branch_performance;

    CREATE TABLE marts.mart_branch_performance AS
    WITH accounts AS (
        SELECT branch_id,
               COUNT(*) AS total_accounts,
               SUM(CASE WHEN is_active::int = 1 THEN 1 ELSE 0 END) AS active_accounts,
               COUNT(DISTINCT customer_key) AS total_customers
        FROM analytics.dim_account
        GROUP BY branch_id
    ),
    employees AS (
        SELECT branch_id,
               COUNT(*) AS employee_count,
               SUM(salary) AS total_salary_cost,
               AVG(salary) AS avg_salary
        FROM analytics.dim_employee
        GROUP BY branch_id
    ),
    loan_payments AS (
        SELECT loan_key,
               SUM(amount_paid) AS total_paid,
               COUNT(*) AS payment_count,
               SUM(CASE WHEN is_late::int = 1 THEN 1 ELSE 0 END) AS late_payments
        FROM analytics.fact_loan_payments
        GROUP BY loan_key
    ),
    loans AS (
        SELECT l.branch_id,
               COUNT(*) AS total_loans,
               SUM(CASE WHEN l.is_active::int = 1 THEN 1 ELSE 0 END) AS active_loans,
               SUM(l.loan_amount) AS total_loan_amount,
               AVG(l.interest_rate) AS avg_interest_rate,
               SUM(COALESCE(p.total_paid, 0)) AS total_loan_collected,
               SUM(COALESCE(p.payment_count, 0)) AS payment_count,
               SUM(COALESCE(p.late_payments, 0)) AS late_payments
        FROM analytics.dim_loan l
        LEFT JOIN loan_payments p ON p.loan_key = l.loan_key
        GROUP BY l.branch_id
    ),
    txns AS (
        SELECT a.branch_id,
               COUNT(*) AS txn_count,
               SUM(t.amount) AS txn_amount
        FROM analytics.fact_transactions t
        JOIN analytics.dim_account a ON a.account_key = t.account_key
        GROUP BY a.branch_id
    )
    SELECT
        b.branch_key,
        b.branch_id,
        b.branch_name,
        b.city,
        b.state,
        b.region,
        b.ifsc_code,
        b.opened_year,
        b.branch_age_band,
        COALESCE(a.total_customers, 0) AS total_customers,
        COALESCE(a.total_accounts, 0)  AS total_accounts,
        COALESCE(a.active_accounts, 0) AS active_accounts,
        COALESCE(e.employee_count, 0)  AS employee_count,
        COALESCE(e.total_salary_cost, 0) AS total_salary_cost,
        ROUND(e.avg_salary::numeric, 2)  AS avg_salary,
        COALESCE(l.total_loans, 0)     AS total_loans,
        COALESCE(l.active_loans, 0)    AS active_loans,
        COALESCE(l.total_loan_amount, 0) AS total_loan_amount,
        ROUND(l.avg_interest_rate::numeric, 2) AS avg_interest_rate,
        COALESCE(l.total_loan_collected, 0) AS total_loan_collected,
        ROUND((100.0 * l.late_payments / NULLIF(l.payment_count, 0))::numeric, 2) AS late_payment_rate_pct,
        COALESCE(t.txn_count, 0)  AS txn_count,
        COALESCE(t.txn_amount, 0) AS txn_amount,
        ROUND((COALESCE(a.total_accounts, 0)::numeric / NULLIF(e.employee_count, 0)), 2) AS accounts_per_employee,
        CURRENT_TIMESTAMP AS mart_refreshed_at
    FROM analytics.dim_branch b
    LEFT JOIN accounts  a ON a.branch_id = b.branch_id
    LEFT JOIN employees e ON e.branch_id = b.branch_id
    LEFT JOIN loans     l ON l.branch_id = b.branch_id
    LEFT JOIN txns      t ON t.branch_id = b.branch_id;

    GET DIAGNOSTICS v_rows_built = ROW_COUNT;

    -- Full refresh has no watermark; record the swap for the audit trail
    v_watermark_advanced := v_rows_previous::TEXT || ' -> ' || v_rows_built::TEXT || ' rows';

    -- ---- Close out the audit run ----
    UPDATE audit.table_runs
    SET status             = 'SUCCESS',
        ended_at           = clock_timestamp(),
        duration_seconds   = ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 3),
        rows_extracted     = v_rows_built,
        rows_landed        = v_rows_built,
        watermark_start    = v_rows_previous::TEXT,
        watermark_end      = v_rows_built::TEXT,
        execution_metadata = jsonb_build_object(
            'rows_previous',       v_rows_previous,
            'rows_built',          v_rows_built,
            'source_batch_id',     p_source_batch_id,
            'refresh_strategy',    'full',
            'watermark_strategy',  'none',
            'force_full',          p_force_full
        )
    WHERE table_run_id = p_table_run_id;

    -- Close the manual pipeline run if this procedure created it
    IF v_audit_seeded THEN
        UPDATE audit.pipeline_runs
        SET status            = 'SUCCESS',
            ended_at          = clock_timestamp(),
            duration_seconds  = ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 3),
            total_tables      = 1,
            successful_tables = 1
        WHERE pipeline_run_id = v_pipeline_run_id
          AND status = 'RUNNING';
    END IF;

    -- Summary (visible in psql / client messages)
    RAISE NOTICE 'mart_branch_performance refresh OK | batch=% | rows previous=% built=% | % sec',
        p_source_batch_id, v_rows_previous, v_rows_built,
        ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 1);

EXCEPTION WHEN OTHERS THEN
    -- Log failure, then re-raise (the rebuild rolls back with the caller).
    -- NOTE: these audit writes survive only if the caller catches the error.
    INSERT INTO audit.pipeline_errors (
        pipeline_run_id,
        table_run_id,
        source_table,
        target_table,
        processing_layer,
        error_category,
        severity,
        error_message,
        error_details,
        is_recoverable,
        resolution_status
    )
    VALUES (
        COALESCE((SELECT pipeline_run_id FROM audit.table_runs WHERE table_run_id = p_table_run_id), v_pipeline_run_id),
        p_table_run_id,
        'analytics (dims + facts)',
        'marts.mart_branch_performance',
        'marts',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',       'marts.sp_load_mart_branch_performance',
            'source_batch_id', p_source_batch_id
        ),
        FALSE,
        'OPEN'
    );

    UPDATE audit.table_runs
    SET status           = 'FAILED',
        ended_at         = clock_timestamp(),
        duration_seconds = ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 3)
    WHERE table_run_id = p_table_run_id;

    IF v_audit_seeded THEN
        UPDATE audit.pipeline_runs
        SET status           = 'FAILED',
            ended_at         = clock_timestamp(),
            duration_seconds = ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 3),
            total_tables     = 1,
            failed_tables    = 1
        WHERE pipeline_run_id = v_pipeline_run_id
          AND status = 'RUNNING';
    END IF;

    RAISE;
END;
$$;

-- ------------------------------------------------------------
-- Manual run (the orchestrator normally passes p_table_run_id)
-- ------------------------------------------------------------
CALL marts.sp_load_mart_branch_performance();
