-- ============================================================
-- Script:   02_sp_load_accounts_scd1.sql
-- Purpose:  Incremental SCD Type 1 load: raw.accounts -> staging.accounts
-- Database: banking_delta (schemas: staging, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\staging\02_accounts_scd1.sql
--
-- Notes:
--   * Watermark comes from audit.etl_watermarks; NULL = bootstrap (load all).
--   * Watermark advances only on success, to max value processed.
--   * Overwritten values go to the shared staging.scd1_history.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('raw.accounts') IS NULL THEN
        RAISE EXCEPTION 'raw.accounts not found - land the source first.';
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
-- Same definition as in 01_customers_scd1.sql - safe to repeat.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.scd1_history (
    history_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name       VARCHAR(128) NOT NULL,   -- e.g. 'staging.accounts'
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
-- Target: current-state accounts (one row per account)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.accounts (
    account_id       INTEGER       NOT NULL,
    customer_id      INTEGER,
    branch_id        INTEGER,
    account_type     VARCHAR(50),
    balance          NUMERIC(15,2),
    open_date        DATE,
    status           VARCHAR(20),
    created_at       TIMESTAMP,
    loaded_at        TIMESTAMP,
    source_batch_id  TEXT,
    source_loaded_at TIMESTAMPTZ,
    row_added_at     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at   TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_accounts PRIMARY KEY (account_id),
    CONSTRAINT chk_accounts_status
        CHECK (status IS NULL OR status IN ('Active', 'Dormant', 'Closed')),
    CONSTRAINT chk_accounts_balance
        CHECK (balance IS NULL OR balance >= 0)
);

COMMENT ON TABLE staging.accounts IS
    'Cleaned accounts, SCD Type 1 (current state, overwritten in place).';

CREATE INDEX IF NOT EXISTS idx_accounts_customer
    ON staging.accounts (customer_id);

DROP TRIGGER IF EXISTS trg_accounts_updated_at ON staging.accounts;
CREATE TRIGGER trg_accounts_updated_at
    BEFORE UPDATE ON staging.accounts
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Seed watermark row for raw.accounts (safe to re-run)
-- ------------------------------------------------------------
INSERT INTO audit.etl_watermarks (
    source_id, config_id, watermark_column, watermark_strategy
)
SELECT t.source_id, t.config_id, '_loaded_at', 'timestamp'
FROM audit.source_tables t
WHERE t.target_schema = 'raw'
  AND t.target_table  = 'accounts'
ON CONFLICT (config_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL staging.sp_load_accounts_scd1();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_load_accounts_scd1(UUID, TEXT, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE staging.sp_load_accounts_scd1(
    IN p_table_run_id     UUID    DEFAULT NULL,
    IN p_source_batch_id  TEXT    DEFAULT NULL,
    IN p_watermark_column TEXT    DEFAULT NULL,
    IN p_force_full       BOOLEAN DEFAULT FALSE,
    IN p_pipeline_run_id  UUID    DEFAULT NULL
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
            'raw.accounts', 'staging.accounts',
            'staging', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Resolve source registration
    SELECT r.source_id, t.config_id
    INTO v_source_id, v_config_id
    FROM audit.source_tables t
    JOIN audit.source_registry r USING (source_id)
    WHERE t.target_schema = 'raw'
      AND t.target_table  = 'accounts';

    IF v_config_id IS NULL THEN
        RAISE EXCEPTION 'raw.accounts is not registered in audit.source_tables - run 03_register_sources.sql.';
    END IF;

    -- Read stored watermark config, then apply defaults / caller override
    SELECT w.watermark_column, w.watermark_strategy, w.last_watermark_value
    INTO v_wm_column, v_wm_strategy, v_last_wm
    FROM audit.etl_watermarks w
    WHERE w.config_id = v_config_id;

    v_wm_column   := COALESCE(p_watermark_column, v_wm_column, '_loaded_at');
    v_wm_strategy := COALESCE(v_wm_strategy, 'timestamp');

    IF v_wm_strategy NOT IN ('timestamp', 'numeric') THEN
        RAISE EXCEPTION 'Unsupported watermark_strategy % for raw.accounts (use timestamp or numeric).', v_wm_strategy;
    END IF;

    -- Watermark column must exist on the source
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'accounts'
          AND column_name  = v_wm_column
    ) THEN
        RAISE EXCEPTION 'Watermark column raw.accounts.% does not exist.', v_wm_column;
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
    IF to_regclass('pg_temp._accounts_src') IS NOT NULL THEN
        DROP TABLE _accounts_src;
    END IF;

    -- Cleaned slice. Format args: (1) watermark column, (2) filter.
    -- Note: a literal % in this SQL must be written %% inside format().
    EXECUTE format($q$
        CREATE TEMP TABLE _accounts_src ON COMMIT DROP AS
        WITH duplicate_filter AS (
            SELECT
                c.*,
                c.%I AS _wm_val,
                -- Filter first, then keep the LATEST row per account
                ROW_NUMBER() OVER (
                    PARTITION BY c.account_id
                    ORDER BY c._batch_id DESC, c._loaded_at DESC
                ) AS rnk
            FROM raw.accounts c
            WHERE %s
        ),
        cleaned_base AS (
            SELECT
                -- IDs: digits only (max 9) so the INT cast cannot fail
                CASE WHEN TRIM(account_id::TEXT) ~ '^[0-9]{1,9}$'
                     THEN TRIM(account_id::TEXT)::INT END AS account_id,
                CASE WHEN TRIM(customer_id::TEXT) ~ '^[0-9]{1,9}$'
                     THEN TRIM(customer_id::TEXT)::INT END AS customer_id,
                CASE WHEN TRIM(branch_id::TEXT) ~ '^[0-9]{1,9}$'
                     THEN TRIM(branch_id::TEXT)::INT END AS branch_id,

                NULLIF(TRIM(account_type), '')::VARCHAR AS account_type,

                -- Max 13 integer digits; cast to column type so history compares equal
                CASE
                    WHEN TRIM(balance::TEXT) ~ '^[0-9]{1,13}(\.[0-9]{1,2})?$'
                    THEN TRIM(balance::TEXT)::NUMERIC(15,2)
                    ELSE NULL
                END AS balance,

                staging.try_date(open_date::TEXT) AS open_date,

                -- INITCAP so 'active' / 'ACTIVE' still match
                CASE
                    WHEN INITCAP(TRIM(status)) IN ('Active', 'Dormant', 'Closed')
                    THEN INITCAP(TRIM(status))
                    ELSE NULL
                END AS status,

                created_at,
                loaded_at,
                _batch_id,
                _loaded_at,
                f._wm_val AS wm_val
            FROM duplicate_filter f
            WHERE rnk = 1
        )
        SELECT
            cb.account_id,
            cb.customer_id,
            cb.branch_id,
            cb.account_type,
            cb.balance,
            cb.open_date,
            cb.status,
            cb.created_at,
            cb.loaded_at,
            cb._batch_id  AS source_batch_id,
            cb._loaded_at AS source_loaded_at,
            cb.wm_val     AS wm_val
        FROM cleaned_base cb
        WHERE cb.account_id IS NOT NULL
    $q$, v_wm_column, v_wm_cond);

    SELECT count(*) INTO v_source_rows FROM _accounts_src;

    -- ===================== INSERT new accounts =====================
    INSERT INTO staging.accounts (
        account_id,
        customer_id,
        branch_id,
        account_type,
        balance,
        open_date,
        status,
        created_at,
        loaded_at,
        source_batch_id,
        source_loaded_at
    )
    SELECT
        s.account_id,
        s.customer_id,
        s.branch_id,
        s.account_type,
        s.balance,
        s.open_date,
        s.status,
        s.created_at,
        s.loaded_at,
        s.source_batch_id,
        s.source_loaded_at
    FROM _accounts_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM staging.accounts t
        WHERE t.account_id = s.account_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- History: one row per changed column, per account (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'staging.accounts',
        s.account_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        s.source_batch_id,
        p_table_run_id
    FROM staging.accounts t
    JOIN _accounts_src s USING (account_id)
    CROSS JOIN LATERAL (VALUES
        ('customer_id',  t.customer_id::TEXT,  s.customer_id::TEXT),
        ('branch_id',    t.branch_id::TEXT,    s.branch_id::TEXT),
        ('account_type', t.account_type::TEXT, s.account_type::TEXT),
        ('balance',      t.balance::TEXT,      s.balance::TEXT),
        ('open_date',    t.open_date::TEXT,    s.open_date::TEXT),
        ('status',       t.status::TEXT,       s.status::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite only rows whose business columns changed
    UPDATE staging.accounts t
    SET
        customer_id      = s.customer_id,
        branch_id        = s.branch_id,
        account_type     = s.account_type,
        balance          = s.balance,
        open_date        = s.open_date,
        status           = s.status,
        created_at       = s.created_at,
        loaded_at        = s.loaded_at,
        source_batch_id  = s.source_batch_id,
        source_loaded_at = s.source_loaded_at
    FROM _accounts_src s
    WHERE t.account_id = s.account_id
      AND ROW(
            t.customer_id, t.branch_id, t.account_type,
            t.balance, t.open_date, t.status
      ) IS DISTINCT FROM ROW(
            s.customer_id, s.branch_id, s.account_type,
            s.balance, s.open_date, s.status
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- Matched rows that were neither inserted nor updated
    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = typed max of the processed slice ----
    IF v_source_rows > 0 THEN
        SELECT max(wm_val)::TEXT INTO v_new_wm FROM _accounts_src;
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
    RAISE NOTICE 'accounts load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
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
        'raw.accounts',
        'staging.accounts',
        'staging',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'staging.sp_load_accounts_scd1',
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
