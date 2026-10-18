-- ============================================================
-- Script:   05_dim_card.sql
-- Purpose:  Incremental SCD Type 1 load: staging.cards -> analytics.dim_card
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\05_dim_card.sql
-- Depends on: 01_dim_customer.sql, 02_dim_account.sql (key lookups)
--
-- Notes:
--   * card_key = surrogate key (facts store this); card_id = natural key.
--   * account_key / customer_key point to dim_account / dim_customer
--     (-1 = Unknown), so card transactions can be analysed by account and
--     customer attributes through the card.
--   * card_category (Debit / Credit) and card_tier (Classic / Gold / Platinum,
--     N/A for debit) are split out of card_type for easy grouping.
--   * credit_limit is kept as an attribute (changes rarely, SCD1 overwrite).
--   * Late-arriving account / customer: cards pointing at -1 are re-processed
--     automatically once the account / customer exists in its dimension.
--   * Row -1 = 'Unknown' member, so facts never carry a NULL / broken key.
--   * Watermark = staging.cards.row_updated_at, stored on the dimension row
--     itself (source_row_updated_at). NULL = bootstrap (load all).
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.dim_card').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.cards') IS NULL THEN
        RAISE EXCEPTION 'staging.cards not found - run 05_sp_load_cards_scd1.sql first.';
    END IF;

    IF to_regclass('staging.scd1_history') IS NULL THEN
        RAISE EXCEPTION 'staging.scd1_history not found - run 01_sp_load_customers_scd1.sql first.';
    END IF;

    IF to_regclass('analytics.dim_customer') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_customer not found - run 01_dim_customer.sql first.';
    END IF;

    IF to_regclass('analytics.dim_account') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_account not found - run 02_dim_account.sql first.';
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
CREATE TABLE IF NOT EXISTS analytics.dim_card (
    card_key              INTEGER       GENERATED ALWAYS AS IDENTITY,   -- surrogate key
    card_id               INTEGER       NOT NULL,                       -- natural key
    account_key           INTEGER       NOT NULL DEFAULT -1,            -- -> dim_account
    customer_key          INTEGER       NOT NULL DEFAULT -1,            -- -> dim_customer
    account_id            INTEGER,                                      -- natural key of account
    customer_id           INTEGER,                                      -- natural key of customer
    card_type             VARCHAR(30)   NOT NULL DEFAULT 'Unknown',
    card_category         VARCHAR(10)   NOT NULL DEFAULT 'Unknown',     -- derived: Debit / Credit
    card_tier             VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived: Classic / Gold / Platinum / N/A
    status                VARCHAR(20)   NOT NULL DEFAULT 'Unknown',
    is_active             BOOLEAN       NOT NULL DEFAULT FALSE,         -- derived: status = 'Active'
    issue_date            DATE,
    issue_year            INTEGER,                                      -- derived
    expiry_date           DATE,
    credit_limit          NUMERIC(12,2),
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_dim_card PRIMARY KEY (card_key),
    CONSTRAINT uq_dim_card_id UNIQUE (card_id),
    CONSTRAINT fk_dim_card_account
        FOREIGN KEY (account_key) REFERENCES analytics.dim_account (account_key),
    CONSTRAINT fk_dim_card_customer
        FOREIGN KEY (customer_key) REFERENCES analytics.dim_customer (customer_key)
);

COMMENT ON TABLE analytics.dim_card IS
    'Card dimension (SCD Type 1). Surrogate key card_key; card_key = -1 is the Unknown member.';

CREATE INDEX IF NOT EXISTS idx_dim_card_account_key
    ON analytics.dim_card (account_key);

CREATE INDEX IF NOT EXISTS idx_dim_card_customer_key
    ON analytics.dim_card (customer_key);

DROP TRIGGER IF EXISTS trg_dim_card_updated_at ON analytics.dim_card;
CREATE TRIGGER trg_dim_card_updated_at
    BEFORE UPDATE ON analytics.dim_card
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Unknown member (facts with no matching card point here)
-- ------------------------------------------------------------
INSERT INTO analytics.dim_card (
    card_key,
    card_id,
    account_key,
    customer_key,
    card_type,
    card_category,
    card_tier,
    status,
    is_active
)
OVERRIDING SYSTEM VALUE
VALUES (-1, -1, -1, -1, 'Unknown', 'Unknown', 'Unknown', 'Unknown', FALSE)
ON CONFLICT (card_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL analytics.sp_load_dim_card();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_dim_card(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_dim_card(
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
            'staging.cards', 'analytics.dim_card',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the dimension
    SELECT max(d.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.dim_card d;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._dim_card_src') IS NOT NULL THEN
        DROP TABLE _dim_card_src;
    END IF;

    -- Slice of staging to process, with surrogate-key lookups and derived attributes
    CREATE TEMP TABLE _dim_card_src ON COMMIT DROP AS
    SELECT
        c.card_id,
        COALESCE(a.account_key, -1)               AS account_key,
        COALESCE(cu.customer_key, -1)             AS customer_key,
        c.account_id,
        c.customer_id,
        COALESCE(c.card_type, 'Unknown')          AS card_type,
        CASE
            WHEN c.card_type = 'Debit'            THEN 'Debit'
            WHEN c.card_type LIKE 'Credit - %'    THEN 'Credit'
            ELSE 'Unknown'
        END                                       AS card_category,
        CASE
            WHEN c.card_type = 'Debit'            THEN 'N/A'
            WHEN c.card_type LIKE 'Credit - %'    THEN SPLIT_PART(c.card_type, ' - ', 2)
            ELSE 'Unknown'
        END                                       AS card_tier,
        COALESCE(c.status, 'Unknown')             AS status,
        COALESCE(c.status = 'Active', FALSE)      AS is_active,
        c.issue_date,
        EXTRACT(YEAR FROM c.issue_date)::INT      AS issue_year,
        c.expiry_date,
        c.credit_limit,
        c.row_updated_at                          AS source_row_updated_at
    FROM staging.cards c
    LEFT JOIN analytics.dim_account a
           ON a.account_id = c.account_id
    LEFT JOIN analytics.dim_customer cu
           ON cu.customer_id = c.customer_id
    LEFT JOIN analytics.dim_card cur
           ON cur.card_id = c.card_id
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR c.row_updated_at > v_last_wm
       -- Late-arriving account / customer: card was loaded with Unknown, parent exists now
       OR (cur.account_key  = -1 AND a.account_key   IS NOT NULL)
       OR (cur.customer_key = -1 AND cu.customer_key IS NOT NULL);

    SELECT count(*) INTO v_source_rows FROM _dim_card_src;

    -- ===================== INSERT new cards =====================
    INSERT INTO analytics.dim_card (
        card_id,
        account_key,
        customer_key,
        account_id,
        customer_id,
        card_type,
        card_category,
        card_tier,
        status,
        is_active,
        issue_date,
        issue_year,
        expiry_date,
        credit_limit,
        source_batch_id,
        source_row_updated_at
    )
    SELECT
        s.card_id, s.account_key, s.customer_key, s.account_id, s.customer_id,
        s.card_type, s.card_category, s.card_tier, s.status, s.is_active,
        s.issue_date, s.issue_year, s.expiry_date, s.credit_limit,
        p_source_batch_id, s.source_row_updated_at
    FROM _dim_card_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.dim_card d
        WHERE d.card_id = s.card_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- History: one row per changed column, per card (must run before UPDATE)
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
        'analytics.dim_card',
        s.card_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.dim_card d
    JOIN _dim_card_src s USING (card_id)
    CROSS JOIN LATERAL (VALUES
        ('account_key',   d.account_key::TEXT,   s.account_key::TEXT),
        ('customer_key',  d.customer_key::TEXT,  s.customer_key::TEXT),
        ('account_id',    d.account_id::TEXT,    s.account_id::TEXT),
        ('customer_id',   d.customer_id::TEXT,   s.customer_id::TEXT),
        ('card_type',     d.card_type::TEXT,     s.card_type::TEXT),
        ('card_category', d.card_category::TEXT, s.card_category::TEXT),
        ('card_tier',     d.card_tier::TEXT,     s.card_tier::TEXT),
        ('status',        d.status::TEXT,        s.status::TEXT),
        ('is_active',     d.is_active::TEXT,     s.is_active::TEXT),
        ('issue_date',    d.issue_date::TEXT,    s.issue_date::TEXT),
        ('issue_year',    d.issue_year::TEXT,    s.issue_year::TEXT),
        ('expiry_date',   d.expiry_date::TEXT,   s.expiry_date::TEXT),
        ('credit_limit',  d.credit_limit::TEXT,  s.credit_limit::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.dim_card d
    SET
        account_key           = s.account_key,
        customer_key          = s.customer_key,
        account_id            = s.account_id,
        customer_id           = s.customer_id,
        card_type             = s.card_type,
        card_category         = s.card_category,
        card_tier             = s.card_tier,
        status                = s.status,
        is_active             = s.is_active,
        issue_date            = s.issue_date,
        issue_year            = s.issue_year,
        expiry_date           = s.expiry_date,
        credit_limit          = s.credit_limit,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _dim_card_src s
    WHERE d.card_id = s.card_id
      AND ROW(
            d.account_key, d.customer_key, d.account_id, d.customer_id, d.card_type,
            d.card_category, d.card_tier, d.status, d.is_active, d.issue_date,
            d.issue_year, d.expiry_date, d.credit_limit, d.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.account_key, s.customer_key, s.account_id, s.customer_id, s.card_type,
            s.card_category, s.card_tier, s.status, s.is_active, s.issue_date,
            s.issue_year, s.expiry_date, s.credit_limit, s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _dim_card_src;
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
            'watermark_column',   'staging.cards.row_updated_at',
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
    RAISE NOTICE 'dim_card load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
        p_source_batch_id, v_source_rows, v_inserted, v_updated, v_unchanged,
        v_history_rows, COALESCE(v_watermark_advanced, 'unchanged');

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
        'staging.cards',
        'analytics.dim_card',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'analytics.sp_load_dim_card',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', 'staging.cards.row_updated_at'
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
CALL analytics.sp_load_dim_card();
