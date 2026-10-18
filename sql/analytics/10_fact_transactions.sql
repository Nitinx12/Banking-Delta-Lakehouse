-- ============================================================
-- Script:   10_fact_transactions.sql
-- Purpose:  Incremental load: staging.transactions -> analytics.fact_transactions
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\10_fact_transactions.sql
-- Depends on: 02_dim_account.sql, 09_dim_txn_profile.sql
--
-- Grain:   one row per account transaction (transaction_id).
-- Measure: amount.
-- Keys:    transaction_id (degenerate dimension / PK),
--          account_key -> dim_account (customer / branch reached from there),
--          txn_profile_key -> dim_txn_profile (type + channel + merchant category,
--          direction Inflow / Outflow),
--          date_key (YYYYMMDD int; -1 = unknown date).
--
-- Notes:
--   * Run sp_load_dim_txn_profile BEFORE sp_load_fact_transactions so every
--     combination has a profile key (the script below does this for the
--     manual run). A combination missing from the dimension lands as -1.
--   * date_key has no foreign key yet: add one when dim_date exists.
--   * Built for a large table (~2M rows), same techniques as the card fact:
--       - procedure-level work_mem, ANALYZE on the temp table
--       - history + UPDATE run BEFORE the INSERT, with a cheap typed ROW compare
--       - watermark = staging.transactions.row_updated_at, stored on the fact
--         row (source_row_updated_at, indexed so max() is instant)
--   * Late-arriving accounts: rows with account_key = -1 are re-linked
--     automatically once the account exists in dim_account (partial index
--     keeps this cheap).
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.fact_transactions').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.transactions') IS NULL THEN
        RAISE EXCEPTION 'staging.transactions not found - run 09_sp_load_transactions_scd1.sql first.';
    END IF;

    IF to_regclass('staging.scd1_history') IS NULL THEN
        RAISE EXCEPTION 'staging.scd1_history not found - run 01_sp_load_customers_scd1.sql first.';
    END IF;

    IF to_regclass('analytics.dim_account') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_account not found - run 02_dim_account.sql first.';
    END IF;

    IF to_regclass('analytics.dim_txn_profile') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_txn_profile not found - run 09_dim_txn_profile.sql first.';
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

-- Index on the staging change column so the incremental filter does not scan 2M rows
CREATE INDEX IF NOT EXISTS idx_transactions_row_updated_at
    ON staging.transactions (row_updated_at);

-- ------------------------------------------------------------
-- Fact table
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.fact_transactions (
    transaction_id        BIGINT        NOT NULL,                       -- degenerate dimension / PK
    account_key           INTEGER       NOT NULL DEFAULT -1,            -- -> dim_account
    txn_profile_key       INTEGER       NOT NULL DEFAULT -1,            -- -> dim_txn_profile
    date_key              INTEGER       NOT NULL DEFAULT -1,            -- YYYYMMDD, -1 = unknown
    txn_date              DATE,
    amount                NUMERIC(14,2),
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_fact_transactions PRIMARY KEY (transaction_id),
    CONSTRAINT fk_fact_txn_account
        FOREIGN KEY (account_key) REFERENCES analytics.dim_account (account_key),
    CONSTRAINT fk_fact_txn_profile
        FOREIGN KEY (txn_profile_key) REFERENCES analytics.dim_txn_profile (txn_profile_key)
);

COMMENT ON TABLE analytics.fact_transactions IS
    'Account transaction fact. Grain: one row per transaction_id. Customer / branch are reached via dim_account.';

CREATE INDEX IF NOT EXISTS idx_fact_txn_account_key
    ON analytics.fact_transactions (account_key);

CREATE INDEX IF NOT EXISTS idx_fact_txn_profile_key
    ON analytics.fact_transactions (txn_profile_key);

CREATE INDEX IF NOT EXISTS idx_fact_txn_date_key
    ON analytics.fact_transactions (date_key);

-- Watermark lookup: max(source_row_updated_at)
CREATE INDEX IF NOT EXISTS idx_fact_txn_source_updated
    ON analytics.fact_transactions (source_row_updated_at);

-- Rows still pointing at the Unknown account (late-arriving accounts)
CREATE INDEX IF NOT EXISTS idx_fact_txn_unknown_account
    ON analytics.fact_transactions (transaction_id)
    WHERE account_key = -1;

DROP TRIGGER IF EXISTS trg_fact_txn_updated_at ON analytics.fact_transactions;
CREATE TRIGGER trg_fact_txn_updated_at
    BEFORE UPDATE ON analytics.fact_transactions
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Load procedure (incremental)
-- Usage: CALL analytics.sp_load_fact_transactions();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- work_mem applies only while this procedure runs.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_fact_transactions(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_fact_transactions(
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

        INSERT INTO audit.pipeline_runs (pipeline_run_id, dag_id, run_type, trigger_type, status)
        VALUES (v_pipeline_run_id, 'manual_sql', 'MANUAL', 'manual', 'RUNNING')
        ON CONFLICT (pipeline_run_id) DO NOTHING;

        INSERT INTO audit.table_runs (
            table_run_id, pipeline_run_id, source_table, target_table,
            processing_layer, operation_type, status
        )
        VALUES (
            p_table_run_id, v_pipeline_run_id,
            'staging.transactions',
            'analytics.fact_transactions',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the fact (index lookup)
    SELECT max(f.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.fact_transactions f;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._fact_txn_src') IS NOT NULL THEN
        DROP TABLE _fact_txn_src;
    END IF;

    -- Slice of staging to process (missing text values -> 'Unknown' to match the dimension)
    CREATE TEMP TABLE _fact_txn_src ON COMMIT DROP AS
    SELECT
        s.transaction_id,
        s.account_id,
        COALESCE(s.txn_type, 'Unknown')           AS txn_type,
        COALESCE(s.channel, 'Unknown')            AS channel,
        COALESCE(s.merchant_category, 'Unknown')  AS merchant_category,
        s.txn_date,
        s.amount,
        s.row_updated_at                          AS source_row_updated_at
    FROM staging.transactions s
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR s.row_updated_at > v_last_wm;

    -- Resolve surrogate keys once, in a second temp table
    IF to_regclass('pg_temp._fact_txn_keyed') IS NOT NULL THEN
        DROP TABLE _fact_txn_keyed;
    END IF;

    CREATE TEMP TABLE _fact_txn_keyed ON COMMIT DROP AS
    SELECT
        t.transaction_id,
        COALESCE(a.account_key, -1)                          AS account_key,
        COALESCE(p.txn_profile_key, -1)                      AS txn_profile_key,
        COALESCE(TO_CHAR(t.txn_date, 'YYYYMMDD')::INT, -1)   AS date_key,
        t.txn_date,
        t.amount,
        t.source_row_updated_at
    FROM _fact_txn_src t
    LEFT JOIN analytics.dim_account a
           ON a.account_id = t.account_id
    LEFT JOIN analytics.dim_txn_profile p
           ON p.txn_type          = t.txn_type
          AND p.channel           = t.channel
          AND p.merchant_category = t.merchant_category;

    -- Temp tables are not auto-analyzed; give the planner real stats
    ANALYZE _fact_txn_keyed;

    SELECT count(*) INTO v_source_rows FROM _fact_txn_keyed;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- Runs before the INSERT so new rows are never compared against themselves.
    -- History: one row per changed column, per transaction (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'analytics.fact_transactions',
        s.transaction_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.fact_transactions f
    JOIN _fact_txn_keyed s USING (transaction_id)
    CROSS JOIN LATERAL (VALUES
        ('account_key',     f.account_key::TEXT,     s.account_key::TEXT),
        ('txn_profile_key', f.txn_profile_key::TEXT, s.txn_profile_key::TEXT),
        ('date_key',        f.date_key::TEXT,        s.date_key::TEXT),
        ('txn_date',        f.txn_date::TEXT,        s.txn_date::TEXT),
        ('amount',          f.amount::TEXT,          s.amount::TEXT)
    ) AS ch(col, old_v, new_v)
    -- Cheap typed compare first: unchanged rows never reach the VALUES expansion
    WHERE ROW(f.account_key, f.txn_profile_key, f.txn_date, f.amount)
          IS DISTINCT FROM
          ROW(s.account_key, s.txn_profile_key, s.txn_date, s.amount)
      AND ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.fact_transactions f
    SET
        account_key           = s.account_key,
        txn_profile_key       = s.txn_profile_key,
        date_key              = s.date_key,
        txn_date              = s.txn_date,
        amount                = s.amount,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _fact_txn_keyed s
    WHERE f.transaction_id = s.transaction_id
      AND ROW(
            f.account_key, f.txn_profile_key, f.date_key, f.txn_date,
            f.amount, f.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.account_key, s.txn_profile_key, s.date_key, s.txn_date,
            s.amount, s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- ===================== INSERT new transactions =====================
    INSERT INTO analytics.fact_transactions (
        transaction_id, account_key, txn_profile_key, date_key, txn_date,
        amount, source_batch_id, source_row_updated_at
    )
    SELECT
        s.transaction_id, s.account_key, s.txn_profile_key, s.date_key, s.txn_date,
        s.amount, p_source_batch_id, s.source_row_updated_at
    FROM _fact_txn_keyed s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.fact_transactions f
        WHERE f.transaction_id = s.transaction_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- Matched rows that were neither inserted nor updated
    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ===================== Late-arriving accounts =====================
    -- Facts stored with the Unknown account (-1) whose account now exists in dim_account.
    -- The partial index on account_key = -1 keeps this scan small.
    UPDATE analytics.fact_transactions f
    SET account_key = a.account_key
    FROM staging.transactions s
    JOIN analytics.dim_account a
      ON a.account_id = s.account_id
     AND a.account_key <> -1
    WHERE f.account_key = -1
      AND f.transaction_id = s.transaction_id;

    GET DIAGNOSTICS v_relinked = ROW_COUNT;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _fact_txn_keyed;
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
            'relinked_accounts',  v_relinked,
            'source_batch_id',    p_source_batch_id,
            'watermark_column',   'staging.transactions.row_updated_at',
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
    RAISE NOTICE 'fact_transactions load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% relinked=% | watermark: % | % sec',
        p_source_batch_id, v_source_rows, v_inserted, v_updated, v_unchanged,
        v_history_rows, v_relinked, COALESCE(v_watermark_advanced, 'unchanged'),
        ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 1);

EXCEPTION WHEN OTHERS THEN
    -- Log failure, then re-raise (load + watermark roll back).
    -- NOTE: these audit writes survive only if the caller catches the error.
    INSERT INTO audit.pipeline_errors (
        pipeline_run_id, table_run_id, source_table, target_table,
        processing_layer, error_category, severity, error_message,
        error_details, is_recoverable, resolution_status
    )
    VALUES (
        COALESCE((SELECT pipeline_run_id FROM audit.table_runs WHERE table_run_id = p_table_run_id), v_pipeline_run_id),
        p_table_run_id,
        'staging.transactions',
        'analytics.fact_transactions',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'analytics.sp_load_fact_transactions',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', 'staging.transactions.row_updated_at'
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
-- Manual run (the orchestrator normally passes p_table_run_id).
-- Profile dimension first, so every combination has a key.
-- ------------------------------------------------------------
CALL analytics.sp_load_dim_txn_profile();
CALL analytics.sp_load_fact_transactions();
