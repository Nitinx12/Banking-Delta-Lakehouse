-- ============================================================
-- Script:   09_dim_txn_profile.sql
-- Purpose:  Build analytics.dim_txn_profile from staging.transactions
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\09_dim_txn_profile.sql
--
-- Notes:
--   * Small "junk" dimension: one row per distinct combination of
--     txn_type + channel + merchant_category that exists in the data.
--     fact_transactions stores txn_profile_key instead of three text columns.
--   * txn_direction (Inflow / Outflow / Unknown) is derived from txn_type.
--   * Nothing here is "history": rows are added when a new combination
--     appears; txn_direction is refreshed if the mapping below changes.
--   * Missing values become 'Unknown'. Row -1 = 'Unknown' / 'Unknown' / 'Unknown'.
--   * No watermark: the procedure reads the DISTINCT combinations of the whole
--     staging table (a few seconds on ~2M rows). Run it BEFORE
--     sp_load_fact_transactions so every combination has a key.
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

-- ------------------------------------------------------------
-- Dimension table
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.dim_txn_profile (
    txn_profile_key   INTEGER       GENERATED ALWAYS AS IDENTITY,   -- surrogate key
    txn_type          VARCHAR(50)   NOT NULL DEFAULT 'Unknown',
    channel           VARCHAR(50)   NOT NULL DEFAULT 'Unknown',
    merchant_category VARCHAR(100)  NOT NULL DEFAULT 'Unknown',
    txn_direction     VARCHAR(10)   NOT NULL DEFAULT 'Unknown',     -- derived: Inflow / Outflow
    row_added_at      TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at    TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_dim_txn_profile PRIMARY KEY (txn_profile_key),
    CONSTRAINT uq_dim_txn_profile UNIQUE (txn_type, channel, merchant_category)
);

COMMENT ON TABLE analytics.dim_txn_profile IS
    'Transaction profile (junk) dimension: one row per txn_type + channel + merchant_category combination. txn_profile_key = -1 is the Unknown member.';

DROP TRIGGER IF EXISTS trg_dim_txn_profile_updated_at ON analytics.dim_txn_profile;
CREATE TRIGGER trg_dim_txn_profile_updated_at
    BEFORE UPDATE ON analytics.dim_txn_profile
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Unknown member (facts with no matching profile point here)
-- ------------------------------------------------------------
INSERT INTO analytics.dim_txn_profile (
    txn_profile_key,
    txn_type,
    channel,
    merchant_category,
    txn_direction
)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'Unknown', 'Unknown', 'Unknown', 'Unknown')
ON CONFLICT (txn_type, channel, merchant_category) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure
-- Usage: CALL analytics.sp_load_dim_txn_profile();
-- p_force_full is accepted only so every analytics procedure has the same
-- signature; this load always reads all distinct combinations.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_dim_txn_profile(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_dim_txn_profile(
    IN p_table_run_id    UUID    DEFAULT NULL,
    IN p_source_batch_id TEXT    DEFAULT NULL,
    IN p_force_full      BOOLEAN DEFAULT FALSE,
    IN p_pipeline_run_id  UUID    DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_started_at   TIMESTAMPTZ := clock_timestamp();
    -- Result counters (reported via NOTICE at the end)
    v_source_rows  BIGINT := 0;
    v_inserted     BIGINT := 0;
    v_updated      BIGINT := 0;
    v_unchanged    BIGINT := 0;
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
            'staging.transactions',
            'analytics.dim_txn_profile',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    WITH combos AS (
        SELECT DISTINCT
            COALESCE(t.txn_type, 'Unknown')          AS txn_type,
            COALESCE(t.channel, 'Unknown')           AS channel,
            COALESCE(t.merchant_category, 'Unknown') AS merchant_category
        FROM staging.transactions t
    ),
    upsert AS (
        INSERT INTO analytics.dim_txn_profile AS d (
            txn_type,
            channel,
            merchant_category,
            txn_direction
        )
        SELECT
            c.txn_type,
            c.channel,
            c.merchant_category,
            CASE
                WHEN c.txn_type IN ('Deposit', 'Transfer In', 'Interest Credit')   THEN 'Inflow'
                WHEN c.txn_type IN ('Withdrawal', 'Transfer Out', 'Fee Debit')     THEN 'Outflow'
                ELSE 'Unknown'
            END
        FROM combos c
        ON CONFLICT (txn_type, channel, merchant_category) DO UPDATE
        SET txn_direction = EXCLUDED.txn_direction
        -- Only touch rows whose derived direction really changed
        WHERE d.txn_direction IS DISTINCT FROM EXCLUDED.txn_direction
        RETURNING (xmax = 0) AS was_insert    -- xmax = 0 -> new row, else updated row
    )
    SELECT
        (SELECT count(*) FROM combos),
        count(*) FILTER (WHERE was_insert),
        count(*) FILTER (WHERE NOT was_insert)
    INTO v_source_rows, v_inserted, v_updated
    FROM upsert;

    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- Heartbeat: this load rewrites all combos but only touches changed
    -- directions, so a no-change run must still advance row_updated_at for
    -- the metadata staleness gate (txn_profile_key <> -1 excludes Unknown).
    IF v_inserted + v_updated = 0 THEN
        UPDATE analytics.dim_txn_profile
        SET    txn_type = txn_type         -- no-op; trigger sets row_updated_at = now()
        WHERE  txn_profile_key = (
            SELECT txn_profile_key
            FROM   analytics.dim_txn_profile
            WHERE  txn_profile_key <> -1
            ORDER  BY txn_profile_key
            LIMIT  1
        );
    END IF;

    -- ---- Close out the audit run ----
    UPDATE audit.table_runs
    SET status             = 'SUCCESS',
        ended_at           = clock_timestamp(),
        duration_seconds   = ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 3),
        rows_extracted     = v_source_rows,
        rows_landed        = v_inserted + v_updated,
        execution_metadata = jsonb_build_object(
            'inserted',           v_inserted,
            'updated',            v_updated,
            'unchanged',          v_unchanged,
            'source_batch_id',    p_source_batch_id,
            'watermark_strategy', 'none (distinct combinations)',
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
    RAISE NOTICE 'dim_txn_profile load OK | batch=% | combinations=% inserted=% updated=% unchanged=%',
        p_source_batch_id, v_source_rows, v_inserted, v_updated, v_unchanged;

EXCEPTION WHEN OTHERS THEN
    -- Log failure, then re-raise (load rolls back).
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
        'staging.transactions',
        'analytics.dim_txn_profile',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',       'analytics.sp_load_dim_txn_profile',
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
CALL analytics.sp_load_dim_txn_profile();
