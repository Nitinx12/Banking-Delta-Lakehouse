-- ============================================================
-- Script:   08_mart_loan_vintage.sql
-- Purpose:  Full refresh: analytics -> marts.mart_loan_vintage
-- Database: banking_delta (schemas: analytics, marts, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1
--      -f .\sql\marts\08_mart_loan_vintage.sql
-- Depends on: 07_dim_loan, 08_fact_loan_payments
--
-- Grain:   one row per disbursement cohort month x months on book x loan type.
-- Measure: repayment volume and delinquency by cohort age.
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

    IF to_regclass('analytics.dim_loan') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_loan not found - run analytics/07_dim_loan.sql first.';
    END IF;

    IF to_regclass('analytics.fact_loan_payments') IS NULL THEN
        RAISE EXCEPTION 'analytics.fact_loan_payments not found - run analytics/08_fact_loan_payments.sql first.';
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
-- Usage: CALL marts.sp_load_mart_loan_vintage();
-- All params optional. No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS marts.sp_load_mart_loan_vintage(
    UUID, TEXT, BOOLEAN, UUID
);

CREATE OR REPLACE PROCEDURE marts.sp_load_mart_loan_vintage(
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
            'analytics.dim_loan', 'marts.mart_loan_vintage',
            'marts', 'REFRESH', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Size of the previous refresh, for the audit summary
    IF to_regclass('marts.mart_loan_vintage') IS NOT NULL THEN
        SELECT count(*) INTO v_rows_previous FROM marts.mart_loan_vintage;
    END IF;

    -- Full refresh: rebuild the aggregate
    DROP TABLE IF EXISTS marts.mart_loan_vintage;

    CREATE TABLE marts.mart_loan_vintage AS
    WITH pay AS (
        SELECT
            l.loan_key,
            DATE_TRUNC('month', l.start_date)::date AS cohort_month,
            l.loan_type,
            (EXTRACT(YEAR FROM p.payment_date)::int * 12
                + EXTRACT(MONTH FROM p.payment_date)::int)
                - (EXTRACT(YEAR FROM l.start_date)::int * 12
                + EXTRACT(MONTH FROM l.start_date)::int) AS months_on_book,
            COALESCE(p.amount_paid, 0)          AS amount_paid,
            COALESCE(p.principal_component, 0)  AS principal_paid,
            COALESCE(p.interest_component, 0)   AS interest_paid,
            CASE WHEN p.is_late::int = 1 THEN 1 ELSE 0 END AS is_late
        FROM analytics.dim_loan l
        JOIN analytics.fact_loan_payments p ON p.loan_key = l.loan_key
        WHERE l.loan_key <> -1
          AND l.start_date IS NOT NULL
          AND l.loan_type IS NOT NULL
          AND p.payment_date IS NOT NULL
    )
    SELECT
        cohort_month,
        months_on_book,
        loan_type,
        COUNT(*)                    AS payment_count,
        COUNT(DISTINCT loan_key)    AS loans_with_payments,
        SUM(amount_paid)            AS amount_paid,
        SUM(principal_paid)         AS principal_paid,
        SUM(interest_paid)          AS interest_paid,
        SUM(is_late)                AS late_payments,
        ROUND((100.0 * SUM(is_late) / COUNT(*))::numeric, 2) AS late_payment_rate_pct,
        CURRENT_TIMESTAMP           AS mart_refreshed_at
    FROM pay
    WHERE months_on_book >= 0
    GROUP BY cohort_month, months_on_book, loan_type;

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
    RAISE NOTICE 'mart_loan_vintage refresh OK | batch=% | rows previous=% built=% | % sec',
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
        'analytics.dim_loan',
        'marts.mart_loan_vintage',
        'marts',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',       'marts.sp_load_mart_loan_vintage',
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
CALL marts.sp_load_mart_loan_vintage();
