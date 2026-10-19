-- ============================================================
-- Script:   07_mart_kpi_monthly.sql
-- Purpose:  Full refresh: analytics dims/facts -> marts.mart_kpi_monthly
-- Database: banking_delta (schemas: analytics, marts, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1
--      -f .\sql\marts\07_mart_kpi_monthly.sql
-- Depends on: 01_dim_customer, 02_dim_account, 06_fact_card_transactions,
--             07_dim_loan, 08_fact_loan_payments, 10_fact_transactions,
--             11_fact_support_tickets
--
-- Grain:   one row per month.
-- Measure: headline bank KPIs (growth, lending, transactions, fraud, support).
--          Cumulative and MoM columns use window functions over month_start.
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

    IF to_regclass('analytics.fact_card_transactions') IS NULL THEN
        RAISE EXCEPTION 'analytics.fact_card_transactions not found - run analytics/06_fact_card_transactions.sql first.';
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
-- Usage: CALL marts.sp_load_mart_kpi_monthly();
-- All params optional. No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS marts.sp_load_mart_kpi_monthly(
    UUID, TEXT, BOOLEAN, UUID
);

CREATE OR REPLACE PROCEDURE marts.sp_load_mart_kpi_monthly(
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
            'analytics (dims + facts)', 'marts.mart_kpi_monthly',
            'marts', 'REFRESH', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Size of the previous refresh, for the audit summary
    IF to_regclass('marts.mart_kpi_monthly') IS NOT NULL THEN
        SELECT count(*) INTO v_rows_previous FROM marts.mart_kpi_monthly;
    END IF;

    -- Full refresh: rebuild the aggregate
    DROP TABLE IF EXISTS marts.mart_kpi_monthly;

    CREATE TABLE marts.mart_kpi_monthly AS
    WITH months AS (
        SELECT CAST(DATE_TRUNC('month', join_date)    AS date) AS month_start FROM analytics.dim_customer
        UNION SELECT CAST(DATE_TRUNC('month', open_date)    AS date) FROM analytics.dim_account
        UNION SELECT CAST(DATE_TRUNC('month', start_date)   AS date) FROM analytics.dim_loan
        UNION SELECT CAST(DATE_TRUNC('month', txn_date)     AS date) FROM analytics.fact_transactions
        UNION SELECT CAST(DATE_TRUNC('month', txn_date)     AS date) FROM analytics.fact_card_transactions
        UNION SELECT CAST(DATE_TRUNC('month', payment_date) AS date) FROM analytics.fact_loan_payments
        UNION SELECT CAST(DATE_TRUNC('month', date_opened)  AS date) FROM analytics.fact_support_tickets
    ),
    new_customers AS (
        SELECT CAST(DATE_TRUNC('month', join_date) AS date) AS month_start,
               COUNT(*) AS new_customers
        FROM analytics.dim_customer GROUP BY 1
    ),
    new_accounts AS (
        SELECT CAST(DATE_TRUNC('month', open_date) AS date) AS month_start,
               COUNT(*) AS new_accounts
        FROM analytics.dim_account GROUP BY 1
    ),
    new_loans AS (
        SELECT CAST(DATE_TRUNC('month', start_date) AS date) AS month_start,
               COUNT(*) AS loans_disbursed,
               SUM(loan_amount) AS loan_amount_disbursed,
               AVG(interest_rate) AS avg_interest_rate
        FROM analytics.dim_loan GROUP BY 1
    ),
    txns AS (
        SELECT CAST(DATE_TRUNC('month', txn_date) AS date) AS month_start,
               COUNT(*) AS txn_count,
               SUM(amount) AS txn_amount,
               COUNT(DISTINCT account_key) AS transacting_accounts
        FROM analytics.fact_transactions GROUP BY 1
    ),
    card_txns AS (
        SELECT CAST(DATE_TRUNC('month', txn_date) AS date) AS month_start,
               COUNT(*) AS card_txn_count,
               SUM(amount) AS card_spend,
               SUM(CASE WHEN is_fraud::int = 1 THEN 1 ELSE 0 END) AS fraud_txn_count,
               SUM(CASE WHEN is_fraud::int = 1 THEN amount ELSE 0 END) AS fraud_amount
        FROM analytics.fact_card_transactions GROUP BY 1
    ),
    payments AS (
        SELECT CAST(DATE_TRUNC('month', payment_date) AS date) AS month_start,
               COUNT(*) AS loan_payment_count,
               SUM(amount_paid) AS loan_collections,
               SUM(interest_component) AS interest_income,
               SUM(CASE WHEN is_late::int = 1 THEN 1 ELSE 0 END) AS late_payments
        FROM analytics.fact_loan_payments GROUP BY 1
    ),
    tickets AS (
        SELECT CAST(DATE_TRUNC('month', date_opened) AS date) AS month_start,
               COUNT(*) AS tickets_opened,
               SUM(CASE WHEN is_resolved::int = 1 THEN 1 ELSE 0 END) AS tickets_resolved,
               AVG(resolution_days) AS avg_resolution_days,
               AVG(satisfaction_score) AS avg_satisfaction_score
        FROM analytics.fact_support_tickets GROUP BY 1
    ),
    kpi AS (
        SELECT
            m.month_start,
            EXTRACT(YEAR FROM m.month_start)::int    AS year,
            EXTRACT(QUARTER FROM m.month_start)::int AS quarter,

            -- Growth
            COALESCE(nc.new_customers, 0) AS new_customers,
            COALESCE(na.new_accounts, 0)  AS new_accounts,

            -- Lending
            COALESCE(nl.loans_disbursed, 0)        AS loans_disbursed,
            COALESCE(nl.loan_amount_disbursed, 0)  AS loan_amount_disbursed,
            ROUND(nl.avg_interest_rate::numeric, 2) AS avg_interest_rate,
            COALESCE(p.loan_payment_count, 0)      AS loan_payment_count,
            COALESCE(p.loan_collections, 0)        AS loan_collections,
            COALESCE(p.interest_income, 0)         AS interest_income,
            ROUND((100.0 * p.late_payments / NULLIF(p.loan_payment_count, 0))::numeric, 2) AS late_payment_rate_pct,

            -- Transactions
            COALESCE(t.txn_count, 0)            AS txn_count,
            COALESCE(t.txn_amount, 0)           AS txn_amount,
            COALESCE(t.transacting_accounts, 0) AS transacting_accounts,
            ROUND((t.txn_amount / NULLIF(t.txn_count, 0))::numeric, 2) AS avg_txn_amount,

            -- Cards & fraud
            COALESCE(c.card_txn_count, 0)  AS card_txn_count,
            COALESCE(c.card_spend, 0)      AS card_spend,
            COALESCE(c.fraud_txn_count, 0) AS fraud_txn_count,
            COALESCE(c.fraud_amount, 0)    AS fraud_amount,
            ROUND((100.0 * c.fraud_txn_count / NULLIF(c.card_txn_count, 0))::numeric, 3) AS fraud_rate_pct,

            -- Customer service
            COALESCE(k.tickets_opened, 0)   AS tickets_opened,
            COALESCE(k.tickets_resolved, 0) AS tickets_resolved,
            ROUND((100.0 * k.tickets_resolved / NULLIF(k.tickets_opened, 0))::numeric, 2) AS ticket_resolution_rate_pct,
            ROUND(k.avg_resolution_days::numeric, 2)    AS avg_resolution_days,
            ROUND(k.avg_satisfaction_score::numeric, 2) AS avg_satisfaction_score
        FROM months m
        LEFT JOIN new_customers nc ON nc.month_start = m.month_start
        LEFT JOIN new_accounts  na ON na.month_start = m.month_start
        LEFT JOIN new_loans     nl ON nl.month_start = m.month_start
        LEFT JOIN txns          t  ON t.month_start  = m.month_start
        LEFT JOIN card_txns     c  ON c.month_start  = m.month_start
        LEFT JOIN payments      p  ON p.month_start  = m.month_start
        LEFT JOIN tickets       k  ON k.month_start  = m.month_start
        WHERE m.month_start IS NOT NULL   -- ignore records with no date
    )
    SELECT
        kpi.*,
        -- Cumulative totals
        SUM(new_customers)         OVER (ORDER BY month_start) AS cumulative_customers,
        SUM(new_accounts)          OVER (ORDER BY month_start) AS cumulative_accounts,
        SUM(loan_amount_disbursed) OVER (ORDER BY month_start) AS cumulative_loan_amount,
        -- Month-over-month growth %
        ROUND((100.0 * (txn_amount - LAG(txn_amount) OVER (ORDER BY month_start))
               / NULLIF(LAG(txn_amount) OVER (ORDER BY month_start), 0))::numeric, 2) AS txn_amount_mom_pct,
        ROUND((100.0 * (card_spend - LAG(card_spend) OVER (ORDER BY month_start))
               / NULLIF(LAG(card_spend) OVER (ORDER BY month_start), 0))::numeric, 2) AS card_spend_mom_pct,
        ROUND((100.0 * (loan_collections - LAG(loan_collections) OVER (ORDER BY month_start))
               / NULLIF(LAG(loan_collections) OVER (ORDER BY month_start), 0))::numeric, 2) AS loan_collections_mom_pct,
        CURRENT_TIMESTAMP AS mart_refreshed_at
    FROM kpi;

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
    RAISE NOTICE 'mart_kpi_monthly refresh OK | batch=% | rows previous=% built=% | % sec',
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
        'marts.mart_kpi_monthly',
        'marts',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',       'marts.sp_load_mart_kpi_monthly',
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
CALL marts.sp_load_mart_kpi_monthly();
