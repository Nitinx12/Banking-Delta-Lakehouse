-- ============================================================
-- Script:   01_mart_customer_360.sql
-- Purpose:  Full refresh: analytics dims/facts -> marts.mart_customer_360
-- Database: banking_delta (schemas: analytics, marts, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1
--      -f .\sql\marts\01_mart_customer_360.sql
-- Depends on: 01_dim_customer, 02_dim_account, 05_dim_card,
--             06_fact_card_transactions, 07_dim_loan,
--             10_fact_transactions, 11_fact_support_tickets
--
-- Grain:   one row per customer.
-- Measure: product counts, balances, activity and support aggregates.
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

    IF to_regclass('analytics.dim_customer') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_customer not found - run analytics/01_dim_customer.sql first.';
    END IF;

    IF to_regclass('analytics.dim_account') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_account not found - run analytics/02_dim_account.sql first.';
    END IF;

    IF to_regclass('analytics.dim_card') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_card not found - run analytics/05_dim_card.sql first.';
    END IF;

    IF to_regclass('analytics.fact_card_transactions') IS NULL THEN
        RAISE EXCEPTION 'analytics.fact_card_transactions not found - run analytics/06_fact_card_transactions.sql first.';
    END IF;

    IF to_regclass('analytics.dim_loan') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_loan not found - run analytics/07_dim_loan.sql first.';
    END IF;

    IF to_regclass('analytics.fact_transactions') IS NULL THEN
        RAISE EXCEPTION 'analytics.fact_transactions not found - run analytics/10_fact_transactions.sql first.';
    END IF;

    IF to_regclass('analytics.fact_support_tickets') IS NULL THEN
        RAISE EXCEPTION 'analytics.fact_support_tickets not found - run analytics/11_fact_support_tickets.sql first.';
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
-- Usage: CALL marts.sp_load_mart_customer_360();
-- All params optional. No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS marts.sp_load_mart_customer_360(
    UUID, TEXT, BOOLEAN, UUID
);

CREATE OR REPLACE PROCEDURE marts.sp_load_mart_customer_360(
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
            'analytics (dims + facts)', 'marts.mart_customer_360',
            'marts', 'REFRESH', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Size of the previous refresh, for the audit summary
    IF to_regclass('marts.mart_customer_360') IS NOT NULL THEN
        SELECT count(*) INTO v_rows_previous FROM marts.mart_customer_360;
    END IF;

    -- Full refresh: rebuild the aggregate
    DROP TABLE IF EXISTS marts.mart_customer_360;

    CREATE TABLE marts.mart_customer_360 AS
    WITH accounts AS (
        SELECT customer_key,
               COUNT(*) AS total_accounts,
               SUM(CASE WHEN is_active::int = 1 THEN 1 ELSE 0 END) AS active_accounts
        FROM analytics.dim_account
        GROUP BY customer_key
    ),
    cards AS (
        SELECT customer_key,
               COUNT(*) AS total_cards,
               SUM(CASE WHEN is_active::int = 1 THEN 1 ELSE 0 END) AS active_cards,
               COALESCE(SUM(credit_limit), 0) AS total_credit_limit
        FROM analytics.dim_card
        GROUP BY customer_key
    ),
    card_activity AS (
        SELECT c.customer_key,
               COUNT(*) AS card_txn_count,
               SUM(ct.amount) AS card_spend,
               SUM(CASE WHEN ct.is_fraud::int = 1 THEN 1 ELSE 0 END) AS card_fraud_txn_count
        FROM analytics.fact_card_transactions ct
        JOIN analytics.dim_card c ON c.card_key = ct.card_key
        GROUP BY c.customer_key
    ),
    loans AS (
        SELECT customer_key,
               COUNT(*) AS total_loans,
               SUM(CASE WHEN is_active::int = 1 THEN 1 ELSE 0 END) AS active_loans,
               SUM(loan_amount) AS total_loan_amount
        FROM analytics.dim_loan
        GROUP BY customer_key
    ),
    account_activity AS (
        SELECT a.customer_key,
               COUNT(*) AS txn_count,
               SUM(t.amount) AS txn_amount,
               MAX(t.txn_date) AS last_txn_date
        FROM analytics.fact_transactions t
        JOIN analytics.dim_account a ON a.account_key = t.account_key
        GROUP BY a.customer_key
    ),
    tickets AS (
        SELECT customer_key,
               COUNT(*) AS total_tickets,
               SUM(CASE WHEN is_resolved::int = 1 THEN 1 ELSE 0 END) AS resolved_tickets,
               AVG(resolution_days) AS avg_resolution_days,
               AVG(satisfaction_score) AS avg_satisfaction_score
        FROM analytics.fact_support_tickets
        GROUP BY customer_key
    )
    SELECT
        c.customer_key,
        c.customer_id,
        c.customer_name,
        c.gender,
        c.age_band,
        c.city,
        c.state,
        c.occupation,
        c.income_band,
        c.annual_income,
        c.join_date,
        c.credit_score,
        c.credit_band,
        COALESCE(a.total_accounts, 0)  AS total_accounts,
        COALESCE(a.active_accounts, 0) AS active_accounts,
        COALESCE(cd.total_cards, 0)    AS total_cards,
        COALESCE(cd.active_cards, 0)   AS active_cards,
        COALESCE(cd.total_credit_limit, 0) AS total_credit_limit,
        COALESCE(l.total_loans, 0)     AS total_loans,
        COALESCE(l.active_loans, 0)    AS active_loans,
        COALESCE(l.total_loan_amount, 0) AS total_loan_amount,
        ROUND((COALESCE(l.total_loan_amount, 0) / NULLIF(c.annual_income, 0))::numeric, 2) AS loan_to_income_ratio,
        COALESCE(aa.txn_count, 0)      AS txn_count,
        COALESCE(aa.txn_amount, 0)     AS txn_amount,
        aa.last_txn_date,
        COALESCE(ca.card_txn_count, 0) AS card_txn_count,
        COALESCE(ca.card_spend, 0)     AS card_spend,
        COALESCE(ca.card_fraud_txn_count, 0) AS card_fraud_txn_count,
        COALESCE(t.total_tickets, 0)   AS total_tickets,
        COALESCE(t.resolved_tickets, 0) AS resolved_tickets,
        ROUND(t.avg_resolution_days::numeric, 2)   AS avg_resolution_days,
        ROUND(t.avg_satisfaction_score::numeric, 2) AS avg_satisfaction_score,
        (CASE WHEN COALESCE(a.total_accounts, 0) > 0 THEN 1 ELSE 0 END
       + CASE WHEN COALESCE(cd.total_cards, 0) > 0 THEN 1 ELSE 0 END
       + CASE WHEN COALESCE(l.total_loans, 0) > 0 THEN 1 ELSE 0 END) AS products_held,
        CURRENT_TIMESTAMP AS mart_refreshed_at
    FROM analytics.dim_customer c
    LEFT JOIN accounts         a  ON a.customer_key  = c.customer_key
    LEFT JOIN cards            cd ON cd.customer_key = c.customer_key
    LEFT JOIN card_activity    ca ON ca.customer_key = c.customer_key
    LEFT JOIN loans            l  ON l.customer_key  = c.customer_key
    LEFT JOIN account_activity aa ON aa.customer_key = c.customer_key
    LEFT JOIN tickets          t  ON t.customer_key  = c.customer_key;

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
    RAISE NOTICE 'mart_customer_360 refresh OK | batch=% | rows previous=% built=% | % sec',
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
        'marts.mart_customer_360',
        'marts',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',       'marts.sp_load_mart_customer_360',
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
CALL marts.sp_load_mart_customer_360();
