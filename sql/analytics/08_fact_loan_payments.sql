-- ============================================================
-- Script:   08_fact_loan_payments.sql
-- Purpose:  Incremental load: staging.loan_payments -> analytics.fact_loan_payments
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\08_fact_loan_payments.sql
-- Depends on: 07_dim_loan.sql (loan_key lookup)
--
-- Grain:   one row per loan payment (payment_id).
-- Measures: amount_paid, principal_component, interest_component, is_late (flag).
-- Keys:    payment_id (degenerate dimension / PK), loan_key -> dim_loan,
--          date_key (YYYYMMDD int; -1 = unknown date).
--          Customer and branch are reached through dim_loan.
--
-- Notes:
--   * amount_check is carried over from staging as a data-quality column
--     (OK / DERIVED / MISMATCH / INCOMPLETE). Filter on it in reports, e.g.
--     exclude MISMATCH rows when summing principal and interest.
--   * date_key has no foreign key yet: add one when dim_date exists.
--   * Same large-table techniques as fact_card_transactions:
--       - procedure-level work_mem, ANALYZE on the temp table
--       - history + UPDATE run BEFORE the INSERT, with a cheap typed ROW compare
--       - watermark = staging.loan_payments.row_updated_at, stored on the fact
--         row (source_row_updated_at, indexed so max() is instant)
--   * Late-arriving loans: rows with loan_key = -1 are re-linked automatically
--     once the loan exists in dim_loan (partial index keeps this cheap).
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.fact_loan_payments').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.loan_payments') IS NULL THEN
        RAISE EXCEPTION 'staging.loan_payments not found - run 08_sp_load_loan_payments_scd1.sql first.';
    END IF;

    IF to_regclass('staging.scd1_history') IS NULL THEN
        RAISE EXCEPTION 'staging.scd1_history not found - run 01_sp_load_customers_scd1.sql first.';
    END IF;

    IF to_regclass('analytics.dim_loan') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_loan not found - run 07_dim_loan.sql first.';
    END IF;

    IF to_regprocedure('audit.set_updated_at()') IS NULL THEN
        RAISE EXCEPTION 'audit.set_updated_at() missing - run 02_audit_tables.sql first.';
    END IF;

    IF to_regclass('audit.table_runs') IS NULL THEN
        RAISE EXCEPTION 'audit.table_runs missing - run 02_audit_tables.sql first.';
    END IF;

    IF to_regclass('audit.pipeline_errors') IS NULL THEN
        RAISE EXCEPTION 'audit.pipeline_errors missing - run 02_audit_tables.sql first.';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS analytics;

-- Index on the staging change column so the incremental filter does not scan every row
CREATE INDEX IF NOT EXISTS idx_loan_payments_row_updated_at
    ON staging.loan_payments (row_updated_at);

-- ------------------------------------------------------------
-- Fact table
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.fact_loan_payments (
    payment_id            BIGINT        NOT NULL,                       -- degenerate dimension / PK
    loan_key              INTEGER       NOT NULL DEFAULT -1,            -- -> dim_loan
    date_key              INTEGER       NOT NULL DEFAULT -1,            -- YYYYMMDD, -1 = unknown
    payment_date          DATE,
    amount_paid           NUMERIC(14,2),
    principal_component   NUMERIC(14,2),
    interest_component    NUMERIC(14,2),
    is_late               BOOLEAN,
    amount_check          VARCHAR(12)   NOT NULL,                       -- OK / DERIVED / MISMATCH / INCOMPLETE
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_fact_loan_payments PRIMARY KEY (payment_id),
    CONSTRAINT fk_fact_lp_loan
        FOREIGN KEY (loan_key) REFERENCES analytics.dim_loan (loan_key),
    CONSTRAINT chk_fact_lp_amount_check
        CHECK (amount_check IN ('OK', 'DERIVED', 'MISMATCH', 'INCOMPLETE'))
);

COMMENT ON TABLE analytics.fact_loan_payments IS
    'Loan payment fact. Grain: one row per payment_id. Customer / branch are reached via dim_loan.';

COMMENT ON COLUMN analytics.fact_loan_payments.amount_check IS
    'Data quality from staging: OK = amount equals principal + interest; DERIVED = one value rebuilt from the other two; MISMATCH = all present but do not add up; INCOMPLETE = cannot be rebuilt.';

CREATE INDEX IF NOT EXISTS idx_fact_lp_loan_key
    ON analytics.fact_loan_payments (loan_key);

CREATE INDEX IF NOT EXISTS idx_fact_lp_date_key
    ON analytics.fact_loan_payments (date_key);

-- Watermark lookup: max(source_row_updated_at)
CREATE INDEX IF NOT EXISTS idx_fact_lp_source_updated
    ON analytics.fact_loan_payments (source_row_updated_at);

-- Rows still pointing at the Unknown loan (late-arriving loans)
CREATE INDEX IF NOT EXISTS idx_fact_lp_unknown_loan
    ON analytics.fact_loan_payments (payment_id)
    WHERE loan_key = -1;

DROP TRIGGER IF EXISTS trg_fact_lp_updated_at ON analytics.fact_loan_payments;
CREATE TRIGGER trg_fact_lp_updated_at
    BEFORE UPDATE ON analytics.fact_loan_payments
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Load procedure (incremental)
-- Usage: CALL analytics.sp_load_fact_loan_payments();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- work_mem applies only while this procedure runs.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_fact_loan_payments(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_fact_loan_payments(
    IN p_table_run_id    UUID    DEFAULT NULL,
    IN p_source_batch_id TEXT    DEFAULT NULL,
    IN p_force_full      BOOLEAN DEFAULT FALSE,
    IN p_pipeline_run_id  UUID    DEFAULT NULL
)
LANGUAGE plpgsql
SET work_mem = '256MB'
AS $$
DECLARE
    v_started_at         TIMESTAMPTZ := clock_timestamp();
    v_last_wm            TIMESTAMPTZ;
    v_new_wm             TIMESTAMPTZ;
    -- Result counters (reported via NOTICE at the end)
    v_source_rows        BIGINT := 0;
    v_inserted           BIGINT := 0;
    v_updated            BIGINT := 0;
    v_unchanged          BIGINT := 0;
    v_history_rows       BIGINT := 0;
    v_relinked           BIGINT := 0;
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
            'staging.loan_payments',
            'analytics.fact_loan_payments',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the fact (index lookup)
    SELECT max(f.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.fact_loan_payments f;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._fact_lp_src') IS NOT NULL THEN
        DROP TABLE _fact_lp_src;
    END IF;

    -- Slice of staging to process, with surrogate-key lookup
    CREATE TEMP TABLE _fact_lp_src ON COMMIT DROP AS
    SELECT
        s.payment_id,
        COALESCE(l.loan_key, -1)                                AS loan_key,
        COALESCE(TO_CHAR(s.payment_date, 'YYYYMMDD')::INT, -1)  AS date_key,
        s.payment_date,
        s.amount_paid,
        s.principal_component,
        s.interest_component,
        s.is_late,
        s.amount_check,
        s.row_updated_at                                        AS source_row_updated_at
    FROM staging.loan_payments s
    LEFT JOIN analytics.dim_loan l
           ON l.loan_id = s.loan_id
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR s.row_updated_at > v_last_wm;

    -- Temp tables are not auto-analyzed; give the planner real stats
    ANALYZE _fact_lp_src;

    SELECT count(*) INTO v_source_rows FROM _fact_lp_src;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- Runs before the INSERT so new rows are never compared against themselves.
    -- History: one row per changed column, per payment (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name,
        record_key,
        changed_column,
        old_value,
        new_value,
        source_batch_id,
        table_run_id
    )
    SELECT
        'analytics.fact_loan_payments',
        s.payment_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.fact_loan_payments f
    JOIN _fact_lp_src s USING (payment_id)
    CROSS JOIN LATERAL (VALUES
        ('loan_key',            f.loan_key::TEXT,            s.loan_key::TEXT),
        ('date_key',            f.date_key::TEXT,            s.date_key::TEXT),
        ('payment_date',        f.payment_date::TEXT,        s.payment_date::TEXT),
        ('amount_paid',         f.amount_paid::TEXT,         s.amount_paid::TEXT),
        ('principal_component', f.principal_component::TEXT, s.principal_component::TEXT),
        ('interest_component',  f.interest_component::TEXT,  s.interest_component::TEXT),
        ('is_late',             f.is_late::TEXT,             s.is_late::TEXT),
        ('amount_check',        f.amount_check::TEXT,        s.amount_check::TEXT)
    ) AS ch(col, old_v, new_v)
    -- Cheap typed compare first: unchanged rows never reach the VALUES expansion
    WHERE ROW(f.loan_key, f.payment_date, f.amount_paid, f.principal_component,
              f.interest_component, f.is_late, f.amount_check)
          IS DISTINCT FROM
          ROW(s.loan_key, s.payment_date, s.amount_paid, s.principal_component,
              s.interest_component, s.is_late, s.amount_check)
      AND ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.fact_loan_payments f
    SET
        loan_key              = s.loan_key,
        date_key              = s.date_key,
        payment_date          = s.payment_date,
        amount_paid           = s.amount_paid,
        principal_component   = s.principal_component,
        interest_component    = s.interest_component,
        is_late               = s.is_late,
        amount_check          = s.amount_check,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _fact_lp_src s
    WHERE f.payment_id = s.payment_id
      AND ROW(
            f.loan_key, f.date_key, f.payment_date, f.amount_paid,
            f.principal_component, f.interest_component, f.is_late,
            f.amount_check, f.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.loan_key, s.date_key, s.payment_date, s.amount_paid,
            s.principal_component, s.interest_component, s.is_late,
            s.amount_check, s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- ====================== INSERT new payments ======================
    INSERT INTO analytics.fact_loan_payments (
        payment_id,
        loan_key,
        date_key,
        payment_date,
        amount_paid,
        principal_component,
        interest_component,
        is_late,
        amount_check,
        source_batch_id,
        source_row_updated_at
    )
    SELECT
        s.payment_id, s.loan_key, s.date_key, s.payment_date, s.amount_paid,
        s.principal_component, s.interest_component, s.is_late, s.amount_check,
        p_source_batch_id, s.source_row_updated_at
    FROM _fact_lp_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.fact_loan_payments f
        WHERE f.payment_id = s.payment_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- Matched rows that were neither inserted nor updated
    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ===================== Late-arriving loans =====================
    -- Facts stored with the Unknown loan (-1) whose loan now exists in dim_loan.
    -- The partial index on loan_key = -1 keeps this scan small.
    UPDATE analytics.fact_loan_payments f
    SET loan_key = l.loan_key
    FROM staging.loan_payments s
    JOIN analytics.dim_loan l
      ON l.loan_id = s.loan_id
     AND l.loan_key <> -1
    WHERE f.loan_key = -1
      AND f.payment_id = s.payment_id;

    GET DIAGNOSTICS v_relinked = ROW_COUNT;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _fact_lp_src;
    v_new_wm := GREATEST(v_new_wm, v_last_wm);   -- GREATEST ignores NULLs; never moves backwards

    IF v_new_wm IS DISTINCT FROM v_last_wm THEN
        -- COALESCE: NULL || text would be NULL on bootstrap
        v_watermark_advanced := COALESCE(v_last_wm::TEXT, '<bootstrap>') || ' -> ' || v_new_wm::TEXT;
    END IF;

    -- ---- Close out the audit run ----
    UPDATE audit.table_runs
    SET status             = 'SUCCESS',
        ended_at           = clock_timestamp(),
        duration_seconds   = ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 3),
        rows_extracted     = v_source_rows,
        rows_landed        = v_inserted + v_updated,
        watermark_start    = v_last_wm::TEXT,
        watermark_end      = v_new_wm::TEXT,
        execution_metadata = jsonb_build_object(
            'inserted',           v_inserted,
            'updated',            v_updated,
            'unchanged',          v_unchanged,
            'history_rows',       v_history_rows,
            'relinked_loans',     v_relinked,
            'source_batch_id',    p_source_batch_id,
            'watermark_column',   'staging.loan_payments.row_updated_at',
            'watermark_strategy', 'timestamp',
            'force_full',         p_force_full
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
    RAISE NOTICE 'fact_loan_payments load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% relinked=% | watermark: % | % sec',
        p_source_batch_id, v_source_rows, v_inserted, v_updated, v_unchanged,
        v_history_rows, v_relinked, COALESCE(v_watermark_advanced, 'unchanged'),
        ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 1);

EXCEPTION WHEN OTHERS THEN
    -- Log failure, then re-raise (load + watermark roll back).
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
        'staging.loan_payments',
        'analytics.fact_loan_payments',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'analytics.sp_load_fact_loan_payments',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', 'staging.loan_payments.row_updated_at'
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
CALL analytics.sp_load_fact_loan_payments();
