-- ============================================================
-- Script:   02_dim_account.sql
-- Purpose:  Incremental SCD Type 1 load: staging.accounts -> analytics.dim_account
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\02_dim_account.sql
-- Depends on: 01_dim_customer.sql (customer_key lookup)
--
-- Notes:
--   * account_key  = surrogate key (facts store this); account_id = natural key.
--   * customer_key = surrogate key of the owner in analytics.dim_customer,
--     so transaction facts can be analysed by customer attributes through
--     the account (fact -> dim_account -> dim_customer). -1 = Unknown customer.
--   * balance is NOT stored here: it changes constantly, so it is a measure
--     for a fact (e.g. a daily / monthly account balance snapshot), not an
--     attribute of the dimension.
--   * branch_id is kept as the natural key for now; when dim_branch exists,
--     add a branch_key column here the same way customer_key is done.
--   * Row -1 = 'Unknown' member, so facts never carry a NULL / broken key.
--   * Watermark = staging.accounts.row_updated_at, stored on the dimension row
--     itself (source_row_updated_at). NULL = bootstrap (load all).
--     Because it lives in the target, it advances only if the load commits.
--   * Late-arriving customers: accounts currently pointing at customer_key = -1
--     are re-processed automatically once their customer appears in dim_customer.
--   * account_age_band drifts with time; use p_force_full = TRUE to refresh it.
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.dim_account').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.accounts') IS NULL THEN
        RAISE EXCEPTION 'staging.accounts not found - run 02_sp_load_accounts_scd1.sql first.';
    END IF;

    IF to_regclass('staging.scd1_history') IS NULL THEN
        RAISE EXCEPTION 'staging.scd1_history not found - run 01_sp_load_customers_scd1.sql first.';
    END IF;

    IF to_regclass('analytics.dim_customer') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_customer not found - run 01_dim_customer.sql first.';
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
CREATE TABLE IF NOT EXISTS analytics.dim_account (
    account_key           INTEGER       GENERATED ALWAYS AS IDENTITY,   -- surrogate key
    account_id            INTEGER       NOT NULL,                       -- natural key
    customer_key          INTEGER       NOT NULL DEFAULT -1,            -- -> dim_customer
    customer_id           INTEGER,                                      -- natural key of owner
    branch_id             INTEGER,                                      -- natural key (dim_branch later)
    account_type          VARCHAR(50)   NOT NULL DEFAULT 'Unknown',
    status                VARCHAR(20)   NOT NULL DEFAULT 'Unknown',
    is_active             BOOLEAN       NOT NULL DEFAULT FALSE,         -- derived: status = 'Active'
    open_date             DATE,
    open_year             INTEGER,                                      -- derived
    account_age_band      VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_dim_account PRIMARY KEY (account_key),
    CONSTRAINT uq_dim_account_id UNIQUE (account_id),
    CONSTRAINT fk_dim_account_customer
        FOREIGN KEY (customer_key) REFERENCES analytics.dim_customer (customer_key)
);

COMMENT ON TABLE analytics.dim_account IS
    'Account dimension (SCD Type 1). Surrogate key account_key; account_key = -1 is the Unknown member. Balance lives in a fact, not here.';

CREATE INDEX IF NOT EXISTS idx_dim_account_customer_key
    ON analytics.dim_account (customer_key);

CREATE INDEX IF NOT EXISTS idx_dim_account_branch_id
    ON analytics.dim_account (branch_id);

DROP TRIGGER IF EXISTS trg_dim_account_updated_at ON analytics.dim_account;
CREATE TRIGGER trg_dim_account_updated_at
    BEFORE UPDATE ON analytics.dim_account
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Unknown member (facts with no matching account point here)
-- ------------------------------------------------------------
INSERT INTO analytics.dim_account (
    account_key, account_id, customer_key, account_type, status,
    is_active, account_age_band
)
OVERRIDING SYSTEM VALUE
VALUES (-1, -1, -1, 'Unknown', 'Unknown', FALSE, 'Unknown')
ON CONFLICT (account_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL analytics.sp_load_dim_account();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_dim_account(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_dim_account(
    IN p_table_run_id    UUID    DEFAULT NULL,
    IN p_source_batch_id TEXT    DEFAULT NULL,
    IN p_force_full      BOOLEAN DEFAULT FALSE,
    IN p_pipeline_run_id  UUID    DEFAULT NULL
)
LANGUAGE plpgsql
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
            'staging.accounts', 'analytics.dim_account',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the dimension
    SELECT max(d.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.dim_account d;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._dim_account_src') IS NOT NULL THEN
        DROP TABLE _dim_account_src;
    END IF;

    -- Slice of staging to process, with surrogate-key lookup and derived attributes
    CREATE TEMP TABLE _dim_account_src ON COMMIT DROP AS
    SELECT
        a.account_id,
        COALESCE(c.customer_key, -1)              AS customer_key,
        a.customer_id,
        a.branch_id,
        COALESCE(a.account_type, 'Unknown')       AS account_type,
        COALESCE(a.status, 'Unknown')             AS status,
        COALESCE(a.status = 'Active', FALSE)      AS is_active,
        a.open_date,
        EXTRACT(YEAR FROM a.open_date)::INT       AS open_year,
        CASE
            WHEN a.open_date IS NULL THEN 'Unknown'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, a.open_date)) < 1 THEN '<1 yr'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, a.open_date)) < 3 THEN '1-3 yrs'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, a.open_date)) < 5 THEN '3-5 yrs'
            ELSE '5+ yrs'
        END                                       AS account_age_band,
        a.row_updated_at                          AS source_row_updated_at
    FROM staging.accounts a
    LEFT JOIN analytics.dim_customer c
           ON c.customer_id = a.customer_id
    LEFT JOIN analytics.dim_account cur
           ON cur.account_id = a.account_id
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR a.row_updated_at > v_last_wm
       -- Late-arriving customer: account was loaded with Unknown owner, owner exists now
       OR (cur.customer_key = -1 AND c.customer_key IS NOT NULL);

    SELECT count(*) INTO v_source_rows FROM _dim_account_src;

    -- ===================== INSERT new accounts =====================
    INSERT INTO analytics.dim_account (
        account_id, customer_key, customer_id, branch_id, account_type, status,
        is_active, open_date, open_year, account_age_band,
        source_batch_id, source_row_updated_at
    )
    SELECT
        s.account_id, s.customer_key, s.customer_id, s.branch_id, s.account_type, s.status,
        s.is_active, s.open_date, s.open_year, s.account_age_band,
        p_source_batch_id, s.source_row_updated_at
    FROM _dim_account_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.dim_account d
        WHERE d.account_id = s.account_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- History: one row per changed column, per account (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'analytics.dim_account',
        s.account_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.dim_account d
    JOIN _dim_account_src s USING (account_id)
    CROSS JOIN LATERAL (VALUES
        ('customer_key',     d.customer_key::TEXT,     s.customer_key::TEXT),
        ('customer_id',      d.customer_id::TEXT,      s.customer_id::TEXT),
        ('branch_id',        d.branch_id::TEXT,        s.branch_id::TEXT),
        ('account_type',     d.account_type::TEXT,     s.account_type::TEXT),
        ('status',           d.status::TEXT,           s.status::TEXT),
        ('is_active',        d.is_active::TEXT,        s.is_active::TEXT),
        ('open_date',        d.open_date::TEXT,        s.open_date::TEXT),
        ('open_year',        d.open_year::TEXT,        s.open_year::TEXT),
        ('account_age_band', d.account_age_band::TEXT, s.account_age_band::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.dim_account d
    SET
        customer_key          = s.customer_key,
        customer_id           = s.customer_id,
        branch_id             = s.branch_id,
        account_type          = s.account_type,
        status                = s.status,
        is_active             = s.is_active,
        open_date             = s.open_date,
        open_year             = s.open_year,
        account_age_band      = s.account_age_band,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _dim_account_src s
    WHERE d.account_id = s.account_id
      AND ROW(
            d.customer_key, d.customer_id, d.branch_id, d.account_type, d.status,
            d.is_active, d.open_date, d.open_year, d.account_age_band,
            d.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.customer_key, s.customer_id, s.branch_id, s.account_type, s.status,
            s.is_active, s.open_date, s.open_year, s.account_age_band,
            s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _dim_account_src;
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
            'source_batch_id',    p_source_batch_id,
            'watermark_column',   'staging.accounts.row_updated_at',
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
    RAISE NOTICE 'dim_account load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
        p_source_batch_id, v_source_rows, v_inserted, v_updated, v_unchanged,
        v_history_rows, COALESCE(v_watermark_advanced, 'unchanged');

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
        'staging.accounts',
        'analytics.dim_account',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'analytics.sp_load_dim_account',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', 'staging.accounts.row_updated_at'
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
CALL analytics.sp_load_dim_account();
