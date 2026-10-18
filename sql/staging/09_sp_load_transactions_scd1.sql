-- ============================================================
-- Script:   09_sp_load_transactions_scd1.sql
-- Purpose:  Incremental SCD Type 1 load: raw.transactions -> staging.transactions
-- Database: banking_delta (schemas: staging, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\staging\09_sp_load_transactions_scd1.sql
--
-- Notes:
--   * Watermark comes from audit.etl_watermarks; NULL = bootstrap (load all).
--   * Watermark advances only on success, to max value processed.
--   * Overwritten values go to the shared staging.scd1_history.
--
-- Built for a large table (~2M rows):
--   * Dedupe on the CLEANED key (no PK clashes), latest row wins,
--     ctid is the final tie-breaker so the pick is deterministic.
--   * Rows are cleaned only AFTER dedupe (each value cleaned once).
--   * Temp table is ANALYZEd so joins get good plans.
--   * History + UPDATE run BEFORE the INSERT.
--   * Change detection uses a cheap typed ROW compare first.
--   * Procedure-level work_mem keeps the big sort/joins in memory.
--
-- Cleaning rules (invalid value -> NULL, row is kept unless noted):
--   transaction_id    digits only, 1-18 long (invalid -> row dropped)
--   account_id        digits only, 1-9 long
--   txn_type          trimmed, Title Case, allowed list only
--   channel           trimmed, canonical case, allowed list only
--   merchant_category trimmed, spaces collapsed, Title Case
--   amount            numeric, up to 2 decimals, greater than 0
--   txn_date          valid date (already typed), not in the future,
--                     not before 2000-01-01
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('raw.transactions') IS NULL THEN
        RAISE EXCEPTION 'raw.transactions not found - land the source first.';
    END IF;

    IF to_regprocedure('audit.set_updated_at()') IS NULL THEN
        RAISE EXCEPTION 'audit.set_updated_at() missing - run 02_audit_tables.sql first.';
    END IF;

    IF to_regclass('audit.etl_watermarks') IS NULL THEN
        RAISE EXCEPTION 'audit.etl_watermarks missing - run 02_audit_tables.sql first.';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS staging;

-- ------------------------------------------------------------
-- Shared SCD1 history (ONE table for all staging tables)
-- Same definition as in the other scripts - safe to repeat.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.scd1_history (
    history_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name       VARCHAR(128) NOT NULL,
    record_key       TEXT         NOT NULL,
    changed_column   VARCHAR(64)  NOT NULL,
    old_value        TEXT,
    new_value        TEXT,
    source_batch_id  TEXT,
    table_run_id     UUID,
    changed_at       TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE staging.scd1_history IS
    'Shared column-level audit trail for SCD Type 1 overwrites on all staging tables.';

CREATE INDEX IF NOT EXISTS idx_scd1_history_key
    ON staging.scd1_history (table_name, record_key, changed_at DESC);

CREATE INDEX IF NOT EXISTS idx_scd1_history_table_run
    ON staging.scd1_history (table_run_id);

-- ------------------------------------------------------------
-- Target: current-state transactions (one row per transaction)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.transactions (
    transaction_id    BIGINT        NOT NULL,
    account_id        INTEGER,
    txn_type          VARCHAR(50),
    channel           VARCHAR(50),
    merchant_category VARCHAR(100),
    amount            NUMERIC(14,2),
    txn_date          DATE,
    created_at        TIMESTAMP,
    loaded_at         TIMESTAMP,
    source_batch_id   TEXT,
    source_loaded_at  TIMESTAMPTZ,
    row_added_at      TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at    TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_transactions PRIMARY KEY (transaction_id),
    CONSTRAINT chk_transactions_amount
        CHECK (amount IS NULL OR amount > 0)
);

COMMENT ON TABLE staging.transactions IS
    'Cleaned transactions, SCD Type 1 (current state, overwritten in place).';

CREATE INDEX IF NOT EXISTS idx_transactions_account
    ON staging.transactions (account_id);

CREATE INDEX IF NOT EXISTS idx_transactions_date
    ON staging.transactions (txn_date);

DROP TRIGGER IF EXISTS trg_transactions_updated_at ON staging.transactions;
CREATE TRIGGER trg_transactions_updated_at
    BEFORE UPDATE ON staging.transactions
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Seed watermark row for raw.transactions (safe to re-run)
-- ------------------------------------------------------------
INSERT INTO audit.etl_watermarks (
    source_id,
    config_id,
    watermark_column,
    watermark_strategy
)
SELECT
    t.source_id,
    t.config_id,
    '_loaded_at',
    'timestamp'
FROM audit.source_tables t
WHERE t.target_schema = 'raw'
  AND t.target_table  = 'transactions'
ON CONFLICT (config_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_load_transactions_scd1(UUID, TEXT, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE staging.sp_load_transactions_scd1(
    IN p_table_run_id     UUID    DEFAULT NULL,
    IN p_source_batch_id  TEXT    DEFAULT NULL,
    IN p_watermark_column TEXT    DEFAULT NULL,
    IN p_force_full       BOOLEAN DEFAULT FALSE,
    IN p_pipeline_run_id  UUID    DEFAULT NULL
)
LANGUAGE plpgsql
SET work_mem = '256MB'
AS $$
DECLARE
    v_source_id          BIGINT;
    v_config_id          BIGINT;
    v_started_at         TIMESTAMPTZ := clock_timestamp();
    v_wm_column          TEXT;
    v_wm_strategy        TEXT;
    v_last_wm            TEXT;
    v_new_wm             TEXT;
    v_wm_cond            TEXT;
    v_source_rows        BIGINT := 0;
    v_inserted           BIGINT := 0;
    v_updated            BIGINT := 0;
    v_unchanged          BIGINT := 0;
    v_history_rows       BIGINT := 0;
    v_watermark_advanced TEXT;
    -- Audit seeding (manual runs without an orchestrator)
    v_pipeline_run_id    UUID    := COALESCE(p_pipeline_run_id, gen_random_uuid());
    v_audit_seeded       BOOLEAN := FALSE;
BEGIN
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
            'raw.transactions', 'staging.transactions',
            'staging', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    SELECT
        r.source_id,
        t.config_id
    INTO v_source_id, v_config_id
    FROM audit.source_tables t
    JOIN audit.source_registry r USING (source_id)
    WHERE t.target_schema = 'raw'
      AND t.target_table  = 'transactions';

    IF v_config_id IS NULL THEN
        RAISE EXCEPTION 'raw.transactions is not registered in audit.source_tables - run 03_register_sources.sql.';
    END IF;

    SELECT
        w.watermark_column,
        w.watermark_strategy,
        w.last_watermark_value
    INTO v_wm_column, v_wm_strategy, v_last_wm
    FROM audit.etl_watermarks w
    WHERE w.config_id = v_config_id;

    v_wm_column   := COALESCE(p_watermark_column, v_wm_column, '_loaded_at');
    v_wm_strategy := COALESCE(v_wm_strategy, 'timestamp');

    IF v_wm_strategy NOT IN ('timestamp', 'numeric') THEN
        RAISE EXCEPTION 'Unsupported watermark_strategy % for raw.transactions (use timestamp or numeric).', v_wm_strategy;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'transactions'
          AND column_name  = v_wm_column
    ) THEN
        RAISE EXCEPTION 'Watermark column raw.transactions.% does not exist.', v_wm_column;
    END IF;

    IF v_last_wm IS NULL OR p_force_full THEN
        v_wm_cond := 'TRUE';
    ELSIF v_wm_strategy = 'timestamp' THEN
        v_wm_cond := format('c.%I > %L::TIMESTAMPTZ', v_wm_column, v_last_wm);
    ELSE
        v_wm_cond := format('c.%I > %L::NUMERIC', v_wm_column, v_last_wm);
    END IF;

    IF to_regclass('pg_temp._transactions_src') IS NOT NULL THEN
        DROP TABLE _transactions_src;
    END IF;

    EXECUTE format($q$
        CREATE TEMP TABLE _transactions_src ON COMMIT DROP AS
        WITH keyed AS (
            SELECT
                CASE WHEN TRIM(c.transaction_id::TEXT) ~ '^[0-9]{1,18}$'
                     THEN TRIM(c.transaction_id::TEXT)::BIGINT END AS txn_key,
                c.account_id,
                c.txn_type,
                c.channel,
                c.merchant_category,
                c.amount,
                c.txn_date,
                c.created_at,
                c.loaded_at,
                c._batch_id,
                c._loaded_at,
                c.ctid AS _row_tid,
                c.%I AS _wm_val
            FROM raw.transactions c
            WHERE %s
        ),
        dedup AS (
            SELECT
                k.*,
                ROW_NUMBER() OVER (
                    PARTITION BY k.txn_key
                    ORDER BY k._batch_id  DESC NULLS LAST,
                             k._loaded_at DESC NULLS LAST,
                             k._row_tid   DESC
                ) AS rnk
            FROM keyed k
            WHERE k.txn_key IS NOT NULL
        )
        SELECT
            d.txn_key AS transaction_id,
            CASE WHEN TRIM(d.account_id::TEXT) ~ '^[0-9]{1,9}$'
                 THEN TRIM(d.account_id::TEXT)::INT END AS account_id,
            CASE
                WHEN INITCAP(NULLIF(TRIM(d.txn_type::TEXT), '')) IN
                     ('Deposit', 'Withdrawal', 'Transfer In', 'Transfer Out',
                      'Fee Debit', 'Interest Credit')
                THEN INITCAP(NULLIF(TRIM(d.txn_type::TEXT), ''))
                ELSE NULL
            END AS txn_type,
            CASE
                WHEN UPPER(TRIM(d.channel::TEXT)) = 'ATM'            THEN 'ATM'
                WHEN UPPER(TRIM(d.channel::TEXT)) = 'BRANCH'         THEN 'Branch'
                WHEN UPPER(TRIM(d.channel::TEXT)) = 'MOBILE APP'     THEN 'Mobile App'
                WHEN UPPER(TRIM(d.channel::TEXT)) = 'ONLINE BANKING' THEN 'Online Banking'
                WHEN UPPER(TRIM(d.channel::TEXT)) = 'POS'            THEN 'POS'
                WHEN UPPER(TRIM(d.channel::TEXT)) = 'UPI'            THEN 'UPI'
                ELSE NULL
            END AS channel,
            INITCAP(NULLIF(regexp_replace(TRIM(d.merchant_category::TEXT), '\s+', ' ', 'g'), ''))
                AS merchant_category,
            CASE
                WHEN TRIM(d.amount::TEXT) ~ '^[0-9]{1,12}(\.[0-9]{1,2})?$'
                THEN NULLIF(TRIM(d.amount::TEXT)::NUMERIC(14,2), 0)
                ELSE NULL
            END AS amount,
            CASE
                WHEN d.txn_date BETWEEN DATE '2000-01-01' AND CURRENT_DATE
                THEN d.txn_date
                ELSE NULL
            END AS txn_date,
            d.created_at,
            d.loaded_at,
            d._batch_id  AS source_batch_id,
            d._loaded_at AS source_loaded_at,
            d._wm_val    AS wm_val
        FROM dedup d
        WHERE d.rnk = 1
    $q$, v_wm_column, v_wm_cond);

    ANALYZE _transactions_src;

    SELECT count(*) INTO v_source_rows FROM _transactions_src;

    -- ============ UPDATE existing: history first, then overwrite ============
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
        'staging.transactions',
        s.transaction_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        s.source_batch_id,
        p_table_run_id
    FROM staging.transactions t
    JOIN _transactions_src s USING (transaction_id)
    CROSS JOIN LATERAL (VALUES
        ('account_id',        t.account_id::TEXT,        s.account_id::TEXT),
        ('txn_type',          t.txn_type::TEXT,          s.txn_type::TEXT),
        ('channel',           t.channel::TEXT,           s.channel::TEXT),
        ('merchant_category', t.merchant_category::TEXT, s.merchant_category::TEXT),
        ('amount',            t.amount::TEXT,            s.amount::TEXT),
        ('txn_date',          t.txn_date::TEXT,          s.txn_date::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ROW(t.account_id, t.txn_type, t.channel, t.merchant_category, t.amount, t.txn_date)
          IS DISTINCT FROM
          ROW(s.account_id, s.txn_type, s.channel, s.merchant_category, s.amount, s.txn_date)
      AND ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    UPDATE staging.transactions t
    SET
        account_id        = s.account_id,
        txn_type          = s.txn_type,
        channel           = s.channel,
        merchant_category = s.merchant_category,
        amount            = s.amount,
        txn_date          = s.txn_date,
        created_at        = s.created_at,
        loaded_at         = s.loaded_at,
        source_batch_id   = s.source_batch_id,
        source_loaded_at  = s.source_loaded_at
    FROM _transactions_src s
    WHERE t.transaction_id = s.transaction_id
      AND ROW(
            t.account_id, t.txn_type, t.channel, t.merchant_category, t.amount, t.txn_date
      ) IS DISTINCT FROM ROW(
            s.account_id, s.txn_type, s.channel, s.merchant_category, s.amount, s.txn_date
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- ===================== INSERT new transactions =====================
    INSERT INTO staging.transactions (
        transaction_id,
        account_id,
        txn_type,
        channel,
        merchant_category,
        amount,
        txn_date,
        created_at,
        loaded_at,
        source_batch_id,
        source_loaded_at
    )
    SELECT
        s.transaction_id,
        s.account_id,
        s.txn_type,
        s.channel,
        s.merchant_category,
        s.amount,
        s.txn_date,
        s.created_at,
        s.loaded_at,
        s.source_batch_id,
        s.source_loaded_at
    FROM _transactions_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM staging.transactions t
        WHERE t.transaction_id = s.transaction_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    v_unchanged := v_source_rows - v_inserted - v_updated;

    IF v_source_rows > 0 THEN
        SELECT max(wm_val)::TEXT INTO v_new_wm FROM _transactions_src;
    ELSE
        v_new_wm := v_last_wm;
    END IF;

    IF v_new_wm IS NOT NULL AND v_new_wm IS DISTINCT FROM v_last_wm THEN
        UPDATE audit.etl_watermarks
        SET previous_watermark_value = last_watermark_value,
            last_watermark_value     = v_new_wm,
            current_batch_start      = v_last_wm,
            current_batch_end        = v_new_wm,
            last_success_table_run   = p_table_run_id,
            last_success_at          = clock_timestamp(),
            lock_version             = lock_version + 1
        WHERE config_id = v_config_id;

        v_watermark_advanced := COALESCE(v_last_wm, '<bootstrap>') || ' -> ' || v_new_wm;
    END IF;

    UPDATE audit.table_runs
    SET status             = 'SUCCESS',
        ended_at           = clock_timestamp(),
        duration_seconds   = ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 3),
        rows_extracted     = v_source_rows,
        rows_landed        = v_inserted + v_updated,
        watermark_start    = v_last_wm,
        watermark_end      = v_new_wm,
        execution_metadata = jsonb_build_object(
            'inserted',           v_inserted,
            'updated',            v_updated,
            'unchanged',          v_unchanged,
            'history_rows',       v_history_rows,
            'source_batch_id',    p_source_batch_id,
            'watermark_column',   v_wm_column,
            'watermark_strategy', v_wm_strategy,
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

    RAISE NOTICE 'transactions load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: % | %s',
        p_source_batch_id, v_source_rows, v_inserted, v_updated, v_unchanged,
        v_history_rows, COALESCE(v_watermark_advanced, 'unchanged'),
        ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 1);

EXCEPTION WHEN OTHERS THEN
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
        'raw.transactions',
        'staging.transactions',
        'staging',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'staging.sp_load_transactions_scd1',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', v_wm_column
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
