-- ============================================================
-- Script:   05_sp_load_cards_scd1.sql
-- Purpose:  Incremental SCD Type 1 load: raw.cards -> staging.cards
-- Database: banking_delta (schemas: staging, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\staging\05_sp_load_cards_scd1.sql
--
-- Notes:
--   * Watermark comes from audit.etl_watermarks; NULL = bootstrap (load all).
--   * Watermark advances only on success, to max value processed.
--   * Overwritten values go to the shared staging.scd1_history.
--
-- Cleaning rules (invalid value -> NULL, row is kept):
--   card_id       digits only, 1-9 long (invalid -> row dropped)
--   customer_id,
--   account_id    digits only, 1-9 long
--   card_type     one of: Debit, Credit - Classic, Credit - Gold, Credit - Platinum
--                 (case / spacing / hyphen spacing are normalised first)
--   issue_date    valid date, not in the future, not before 1990-01-01
--   expiry_date   valid date, not before issue_date, not after 2100-12-31
--   credit_limit  numeric, up to 2 decimals, greater than 0; Debit cards -> NULL
--   status        one of: Active, Blocked, Expired (case-insensitive)
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('raw.cards') IS NULL THEN
        RAISE EXCEPTION 'raw.cards not found - land the source first.';
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
-- Shared helper: text -> DATE, NULL when invalid (never raises).
-- TO_DATE errors on values like 2023-02-30, which would fail the load.
-- Same definition as in the other scripts - safe to repeat.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION staging.try_date(p TEXT)
RETURNS DATE
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    s   TEXT := TRIM(p);
    y   INT;
    m   INT;
    d   INT;
    dim INT;
BEGIN
    IF s IS NULL OR s !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RETURN NULL;
    END IF;

    y := SUBSTR(s, 1, 4)::INT;
    m := SUBSTR(s, 6, 2)::INT;
    d := SUBSTR(s, 9, 2)::INT;

    IF y < 1 OR m NOT BETWEEN 1 AND 12 OR d < 1 THEN
        RETURN NULL;
    END IF;

    dim := CASE
               WHEN m = 2 AND y % 4 = 0 AND (y % 100 <> 0 OR y % 400 = 0) THEN 29
               WHEN m = 2 THEN 28
               WHEN m IN (4, 6, 9, 11) THEN 30
               ELSE 31
           END;

    IF d > dim THEN
        RETURN NULL;
    END IF;

    RETURN make_date(y, m, d);
END;
$$;

-- ------------------------------------------------------------
-- Shared SCD1 history (ONE table for all staging tables)
-- Same definition as in the other scripts - safe to repeat.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.scd1_history (
    history_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name       VARCHAR(128) NOT NULL,   -- e.g. 'staging.cards'
    record_key       TEXT         NOT NULL,   -- business key as text (composite: join with '|')
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
-- Target: current-state cards (one row per card)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.cards (
    card_id          INTEGER       NOT NULL,
    customer_id      INTEGER,
    account_id       INTEGER,
    card_type        VARCHAR(30),
    issue_date       DATE,
    expiry_date      DATE,
    credit_limit     NUMERIC(12,2),
    status           VARCHAR(20),
    created_at       TIMESTAMP,
    loaded_at        TIMESTAMP,
    source_batch_id  TEXT,
    source_loaded_at TIMESTAMPTZ,
    row_added_at     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at   TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_cards PRIMARY KEY (card_id),
    CONSTRAINT chk_cards_card_type
        CHECK (card_type IS NULL
               OR card_type IN ('Debit', 'Credit - Classic', 'Credit - Gold', 'Credit - Platinum')),
    CONSTRAINT chk_cards_status
        CHECK (status IS NULL OR status IN ('Active', 'Blocked', 'Expired')),
    CONSTRAINT chk_cards_credit_limit
        CHECK (credit_limit IS NULL OR credit_limit > 0),
    CONSTRAINT chk_cards_dates
        CHECK (issue_date IS NULL OR expiry_date IS NULL OR expiry_date >= issue_date)
);

COMMENT ON TABLE staging.cards IS
    'Cleaned cards, SCD Type 1 (current state, overwritten in place).';

CREATE INDEX IF NOT EXISTS idx_cards_customer
    ON staging.cards (customer_id);

CREATE INDEX IF NOT EXISTS idx_cards_account
    ON staging.cards (account_id);

DROP TRIGGER IF EXISTS trg_cards_updated_at ON staging.cards;
CREATE TRIGGER trg_cards_updated_at
    BEFORE UPDATE ON staging.cards
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

-- ------------------------------------------------------------
-- Seed watermark row for raw.cards (safe to re-run)
-- ------------------------------------------------------------
INSERT INTO audit.etl_watermarks (
    source_id, config_id, watermark_column, watermark_strategy
)
SELECT t.source_id, t.config_id, '_loaded_at', 'timestamp'
FROM audit.source_tables t
WHERE t.target_schema = 'raw'
  AND t.target_table  = 'cards'
ON CONFLICT (config_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL staging.sp_load_cards_scd1();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE staging.sp_load_cards_scd1(
    IN p_table_run_id     UUID    DEFAULT NULL,
    IN p_source_batch_id  TEXT    DEFAULT NULL,
    IN p_watermark_column TEXT    DEFAULT NULL,
    IN p_force_full       BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
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
    -- Result counters (reported via NOTICE at the end)
    v_source_rows        BIGINT := 0;
    v_inserted           BIGINT := 0;
    v_updated            BIGINT := 0;
    v_unchanged          BIGINT := 0;
    v_history_rows       BIGINT := 0;
    v_watermark_advanced TEXT;
BEGIN
    -- Defaults for manual runs
    p_table_run_id    := COALESCE(p_table_run_id, gen_random_uuid());
    p_source_batch_id := COALESCE(p_source_batch_id,
                                  'manual_' || to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS'));
    p_force_full      := COALESCE(p_force_full, FALSE);

    -- Resolve source registration
    SELECT r.source_id, t.config_id
    INTO v_source_id, v_config_id
    FROM audit.source_tables t
    JOIN audit.source_registry r USING (source_id)
    WHERE t.target_schema = 'raw'
      AND t.target_table  = 'cards';

    IF v_config_id IS NULL THEN
        RAISE EXCEPTION 'raw.cards is not registered in audit.source_tables - run 03_register_sources.sql.';
    END IF;

    -- Read stored watermark config, then apply defaults / caller override
    SELECT w.watermark_column, w.watermark_strategy, w.last_watermark_value
    INTO v_wm_column, v_wm_strategy, v_last_wm
    FROM audit.etl_watermarks w
    WHERE w.config_id = v_config_id;

    v_wm_column   := COALESCE(p_watermark_column, v_wm_column, '_loaded_at');
    v_wm_strategy := COALESCE(v_wm_strategy, 'timestamp');

    IF v_wm_strategy NOT IN ('timestamp', 'numeric') THEN
        RAISE EXCEPTION 'Unsupported watermark_strategy % for raw.cards (use timestamp or numeric).', v_wm_strategy;
    END IF;

    -- Watermark column must exist on the source
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'cards'
          AND column_name  = v_wm_column
    ) THEN
        RAISE EXCEPTION 'Watermark column raw.cards.% does not exist.', v_wm_column;
    END IF;

    -- Build filter: none for bootstrap / force-full, else strictly newer rows
    IF v_last_wm IS NULL OR p_force_full THEN
        v_wm_cond := 'TRUE';
    ELSIF v_wm_strategy = 'timestamp' THEN
        v_wm_cond := format('c.%I > %L::TIMESTAMPTZ', v_wm_column, v_last_wm);
    ELSE
        v_wm_cond := format('c.%I > %L::NUMERIC', v_wm_column, v_last_wm);
    END IF;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._cards_src') IS NOT NULL THEN
        DROP TABLE _cards_src;
    END IF;

    -- Cleaned slice. Format args: (1) watermark column, (2) filter.
    -- Note: a literal % in this SQL must be written %% inside format().
    EXECUTE format($q$
        CREATE TEMP TABLE _cards_src ON COMMIT DROP AS
        WITH duplicate_filter AS (
            SELECT
                c.*,
                c.%I AS _wm_val,
                -- Filter first, then keep the LATEST row per card
                ROW_NUMBER() OVER (
                    PARTITION BY c.card_id
                    ORDER BY c._batch_id DESC NULLS LAST,
                             c._loaded_at DESC NULLS LAST
                ) AS rnk
            FROM raw.cards c
            WHERE %s
        ),
        cleaned_base AS (
            SELECT
                -- IDs: digits only (max 9) so the INT cast cannot fail
                CASE WHEN TRIM(card_id::TEXT) ~ '^[0-9]{1,9}$'
                     THEN TRIM(card_id::TEXT)::INT END AS card_id,
                CASE WHEN TRIM(customer_id::TEXT) ~ '^[0-9]{1,9}$'
                     THEN TRIM(customer_id::TEXT)::INT END AS customer_id,
                CASE WHEN TRIM(account_id::TEXT) ~ '^[0-9]{1,9}$'
                     THEN TRIM(account_id::TEXT)::INT END AS account_id,

                -- Must match the allowed list after normalising
                CASE
                    WHEN p.ct IN ('Debit', 'Credit - Classic', 'Credit - Gold', 'Credit - Platinum')
                    THEN p.ct
                    ELSE NULL
                END AS card_type,

                -- Valid date, not in the future, not before 1990
                CASE
                    WHEN p.idt BETWEEN DATE '1990-01-01' AND CURRENT_DATE
                    THEN p.idt
                    ELSE NULL
                END AS issue_date,

                -- Valid date, on/after issue date, not after 2100
                CASE
                    WHEN p.edt BETWEEN GREATEST(COALESCE(p.idt, DATE '1990-01-01'), DATE '1990-01-01')
                                   AND DATE '2100-12-31'
                    THEN p.edt
                    ELSE NULL
                END AS expiry_date,

                -- Debit cards have no credit limit; else numeric > 0 (max 10 integer digits)
                CASE
                    WHEN p.ct = 'Debit' THEN NULL
                    WHEN TRIM(credit_limit::TEXT) ~ '^[0-9]{1,10}(\.[0-9]{1,2})?$'
                    THEN NULLIF(TRIM(credit_limit::TEXT)::NUMERIC(12,2), 0)
                    ELSE NULL
                END AS credit_limit,

                -- INITCAP so 'active' / 'ACTIVE' still match
                CASE
                    WHEN INITCAP(TRIM(status::TEXT)) IN ('Active', 'Blocked', 'Expired')
                    THEN INITCAP(TRIM(status::TEXT))
                    ELSE NULL
                END AS status,

                created_at,
                loaded_at,
                _batch_id,
                _loaded_at,
                f._wm_val AS wm_val
            FROM duplicate_filter f
            -- Normalise / parse once, reuse above
            CROSS JOIN LATERAL (
                SELECT
                    INITCAP(regexp_replace(
                        regexp_replace(TRIM(f.card_type::TEXT), '\s*-\s*', ' - ', 'g'),
                        '\s+', ' ', 'g'))                 AS ct,
                    staging.try_date(f.issue_date::TEXT)  AS idt,
                    staging.try_date(f.expiry_date::TEXT) AS edt
            ) p
            WHERE rnk = 1
        )
        SELECT
            cb.card_id,
            cb.customer_id,
            cb.account_id,
            cb.card_type,
            cb.issue_date,
            cb.expiry_date,
            cb.credit_limit,
            cb.status,
            cb.created_at,
            cb.loaded_at,
            cb._batch_id  AS source_batch_id,
            cb._loaded_at AS source_loaded_at,
            cb.wm_val     AS wm_val
        FROM cleaned_base cb
        WHERE cb.card_id IS NOT NULL
    $q$, v_wm_column, v_wm_cond);

    SELECT count(*) INTO v_source_rows FROM _cards_src;

    -- ===================== INSERT new cards =====================
    INSERT INTO staging.cards (
        card_id,
        customer_id,
        account_id,
        card_type,
        issue_date,
        expiry_date,
        credit_limit,
        status,
        created_at,
        loaded_at,
        source_batch_id,
        source_loaded_at
    )
    SELECT
        s.card_id,
        s.customer_id,
        s.account_id,
        s.card_type,
        s.issue_date,
        s.expiry_date,
        s.credit_limit,
        s.status,
        s.created_at,
        s.loaded_at,
        s.source_batch_id,
        s.source_loaded_at
    FROM _cards_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM staging.cards t
        WHERE t.card_id = s.card_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- History: one row per changed column, per card (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'staging.cards',
        s.card_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        s.source_batch_id,
        p_table_run_id
    FROM staging.cards t
    JOIN _cards_src s USING (card_id)
    CROSS JOIN LATERAL (VALUES
        ('customer_id',  t.customer_id::TEXT,  s.customer_id::TEXT),
        ('account_id',   t.account_id::TEXT,   s.account_id::TEXT),
        ('card_type',    t.card_type::TEXT,    s.card_type::TEXT),
        ('issue_date',   t.issue_date::TEXT,   s.issue_date::TEXT),
        ('expiry_date',  t.expiry_date::TEXT,  s.expiry_date::TEXT),
        ('credit_limit', t.credit_limit::TEXT, s.credit_limit::TEXT),
        ('status',       t.status::TEXT,       s.status::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite only rows whose business columns changed
    UPDATE staging.cards t
    SET
        customer_id      = s.customer_id,
        account_id       = s.account_id,
        card_type        = s.card_type,
        issue_date       = s.issue_date,
        expiry_date      = s.expiry_date,
        credit_limit     = s.credit_limit,
        status           = s.status,
        created_at       = s.created_at,
        loaded_at        = s.loaded_at,
        source_batch_id  = s.source_batch_id,
        source_loaded_at = s.source_loaded_at
    FROM _cards_src s
    WHERE t.card_id = s.card_id
      AND ROW(
            t.customer_id, t.account_id, t.card_type, t.issue_date,
            t.expiry_date, t.credit_limit, t.status
      ) IS DISTINCT FROM ROW(
            s.customer_id, s.account_id, s.card_type, s.issue_date,
            s.expiry_date, s.credit_limit, s.status
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- Matched rows that were neither inserted nor updated
    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = typed max of the processed slice ----
    IF v_source_rows > 0 THEN
        SELECT max(wm_val)::TEXT INTO v_new_wm FROM _cards_src;
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

        -- COALESCE: NULL || text would be NULL on bootstrap
        v_watermark_advanced := COALESCE(v_last_wm, '<bootstrap>') || ' -> ' || v_new_wm;
    END IF;

    -- ---- Close out the audit run ----
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

    -- Summary (visible in psql / client messages)
    RAISE NOTICE 'cards load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
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
    SELECT
        tr.pipeline_run_id,
        p_table_run_id,
        'raw.cards',
        'staging.cards',
        'staging',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'staging.sp_load_cards_scd1',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', v_wm_column
        ),
        FALSE,
        'OPEN'
    FROM audit.table_runs tr
    WHERE tr.table_run_id = p_table_run_id;

    UPDATE audit.table_runs
    SET status           = 'FAILED',
        ended_at         = clock_timestamp(),
        duration_seconds = ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 3)
    WHERE table_run_id = p_table_run_id;

    RAISE;
END;
$$;
