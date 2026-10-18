-- ============================================================
-- Script:   06_fact_card_transactions.sql
-- Purpose:  Incremental load: staging.card_transactions -> analytics.fact_card_transactions
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\06_fact_card_transactions.sql
-- Depends on: 05_dim_card.sql (card_key lookup)
--
-- Grain:   one row per card transaction (card_txn_id).
-- Measures: amount, is_fraud (flag).
-- Keys:    card_txn_id (degenerate dimension / PK), card_key -> dim_card,
--          date_key (YYYYMMDD int; -1 = unknown date).
--          Account and customer are reached through dim_card.
--
-- Notes:
--   * date_key has no foreign key yet: add one when dim_date exists.
--   * merchant_category stays as a text column for now; it moves into a
--     small dimension (dim_txn_profile) later.
--   * Built for a large table (~3M rows), same techniques as the staging load:
--       - procedure-level work_mem, ANALYZE on the temp table
--       - history + UPDATE run BEFORE the INSERT, with a cheap typed ROW compare
--       - watermark = staging.card_transactions.row_updated_at, stored on the
--         fact row (source_row_updated_at, indexed so max() is instant)
--   * Late-arriving cards: rows with card_key = -1 are re-linked automatically
--     once the card exists in dim_card (partial index keeps this cheap).
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.fact_card_transactions').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.card_transactions') IS NULL THEN
        RAISE EXCEPTION 'staging.card_transactions not found - run 06_sp_load_card_transactions_scd1.sql first.';
    END IF;

    IF to_regclass('staging.scd1_history') IS NULL THEN
        RAISE EXCEPTION 'staging.scd1_history not found - run 01_sp_load_customers_scd1.sql first.';
    END IF;

    IF to_regclass('analytics.dim_card') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_card not found - run 05_dim_card.sql first.';
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

-- Index on the staging change column so the incremental filter does not scan 3M rows
CREATE INDEX IF NOT EXISTS idx_card_transactions_row_updated_at
    ON staging.card_transactions (row_updated_at);

-- ------------------------------------------------------------
-- Fact table
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.fact_card_transactions (
    card_txn_id           BIGINT        NOT NULL,                       -- degenerate dimension / PK
    card_key              INTEGER       NOT NULL DEFAULT -1,            -- -> dim_card
    date_key              INTEGER       NOT NULL DEFAULT -1,            -- YYYYMMDD, -1 = unknown
    txn_date              DATE,
    merchant_category     VARCHAR(100)  NOT NULL DEFAULT 'Unknown',
    is_fraud              BOOLEAN,
    amount                NUMERIC(14,2),
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_fact_card_transactions PRIMARY KEY (card_txn_id),
    CONSTRAINT fk_fact_cct_card
        FOREIGN KEY (card_key) REFERENCES analytics.dim_card (card_key)
);

COMMENT ON TABLE analytics.fact_card_transactions IS
    'Card transaction fact. Grain: one row per card_txn_id. Account / customer are reached via dim_card.';

CREATE INDEX IF NOT EXISTS idx_fact_cct_card_key
    ON analytics.fact_card_transactions (card_key);

CREATE INDEX IF NOT EXISTS idx_fact_cct_date_key
    ON analytics.fact_card_transactions (date_key);

-- Watermark lookup: max(source_row_updated_at)
CREATE INDEX IF NOT EXISTS idx_fact_cct_source_updated
    ON analytics.fact_card_transactions (source_row_updated_at);

-- Rows still pointing at the Unknown card (late-arriving cards)
CREATE INDEX IF NOT EXISTS idx_fact_cct_unknown_card
    ON analytics.fact_card_transactions (card_txn_id)
    WHERE card_key = -1;

DROP TRIGGER IF EXISTS trg_fact_cct_updated_at ON analytics.fact_card_transactions;
CREATE TRIGGER trg_fact_cct_updated_at
    BEFORE UPDATE ON analytics.fact_card_transactions
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Load procedure (incremental)
-- Usage: CALL analytics.sp_load_fact_card_transactions();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- work_mem applies only while this procedure runs.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_fact_card_transactions(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_fact_card_transactions(
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
            'staging.card_transactions',
            'analytics.fact_card_transactions',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the fact (index lookup)
    SELECT max(f.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.fact_card_transactions f;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._fact_cct_src') IS NOT NULL THEN
        DROP TABLE _fact_cct_src;
    END IF;

    -- Slice of staging to process, with surrogate-key lookups
    CREATE TEMP TABLE _fact_cct_src ON COMMIT DROP AS
    SELECT
        s.card_txn_id,
        COALESCE(c.card_key, -1)                              AS card_key,
        COALESCE(TO_CHAR(s.txn_date, 'YYYYMMDD')::INT, -1)    AS date_key,
        s.txn_date,
        COALESCE(s.merchant_category, 'Unknown')              AS merchant_category,
        s.is_fraud,
        s.amount,
        s.row_updated_at                                      AS source_row_updated_at
    FROM staging.card_transactions s
    LEFT JOIN analytics.dim_card c
           ON c.card_id = s.card_id
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR s.row_updated_at > v_last_wm;

    -- Temp tables are not auto-analyzed; give the planner real stats
    ANALYZE _fact_cct_src;

    SELECT count(*) INTO v_source_rows FROM _fact_cct_src;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- Runs before the INSERT so new rows are never compared against themselves.
    -- History: one row per changed column, per transaction (must run before UPDATE)
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
        'analytics.fact_card_transactions',
        s.card_txn_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.fact_card_transactions f
    JOIN _fact_cct_src s USING (card_txn_id)
    CROSS JOIN LATERAL (VALUES
        ('card_key',          f.card_key::TEXT,          s.card_key::TEXT),
        ('date_key',          f.date_key::TEXT,          s.date_key::TEXT),
        ('txn_date',          f.txn_date::TEXT,          s.txn_date::TEXT),
        ('merchant_category', f.merchant_category::TEXT, s.merchant_category::TEXT),
        ('is_fraud',          f.is_fraud::TEXT,          s.is_fraud::TEXT),
        ('amount',            f.amount::TEXT,            s.amount::TEXT)
    ) AS ch(col, old_v, new_v)
    -- Cheap typed compare first: unchanged rows never reach the VALUES expansion
    WHERE ROW(f.card_key, f.txn_date, f.merchant_category, f.is_fraud, f.amount)
          IS DISTINCT FROM
          ROW(s.card_key, s.txn_date, s.merchant_category, s.is_fraud, s.amount)
      AND ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.fact_card_transactions f
    SET
        card_key              = s.card_key,
        date_key              = s.date_key,
        txn_date              = s.txn_date,
        merchant_category     = s.merchant_category,
        is_fraud              = s.is_fraud,
        amount                = s.amount,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _fact_cct_src s
    WHERE f.card_txn_id = s.card_txn_id
      AND ROW(
            f.card_key, f.date_key, f.txn_date, f.merchant_category,
            f.is_fraud, f.amount, f.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.card_key, s.date_key, s.txn_date, s.merchant_category,
            s.is_fraud, s.amount, s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- ===================== INSERT new transactions =====================
    INSERT INTO analytics.fact_card_transactions (
        card_txn_id,
        card_key,
        date_key,
        txn_date,
        merchant_category,
        is_fraud,
        amount,
        source_batch_id,
        source_row_updated_at
    )
    SELECT
        s.card_txn_id, s.card_key, s.date_key, s.txn_date, s.merchant_category,
        s.is_fraud, s.amount, p_source_batch_id, s.source_row_updated_at
    FROM _fact_cct_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.fact_card_transactions f
        WHERE f.card_txn_id = s.card_txn_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- Matched rows that were neither inserted nor updated
    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ===================== Late-arriving cards =====================
    -- Facts stored with the Unknown card (-1) whose card now exists in dim_card.
    -- The partial index on card_key = -1 keeps this scan small.
    UPDATE analytics.fact_card_transactions f
    SET card_key = c.card_key
    FROM staging.card_transactions s
    JOIN analytics.dim_card c
      ON c.card_id = s.card_id
     AND c.card_key <> -1
    WHERE f.card_key = -1
      AND f.card_txn_id = s.card_txn_id;

    GET DIAGNOSTICS v_relinked = ROW_COUNT;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _fact_cct_src;
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
            'relinked_cards',     v_relinked,
            'source_batch_id',    p_source_batch_id,
            'watermark_column',   'staging.card_transactions.row_updated_at',
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
    RAISE NOTICE 'fact_card_transactions load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% relinked=% | watermark: % | % sec',
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
        'staging.card_transactions',
        'analytics.fact_card_transactions',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'analytics.sp_load_fact_card_transactions',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', 'staging.card_transactions.row_updated_at'
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
CALL analytics.sp_load_fact_card_transactions();
