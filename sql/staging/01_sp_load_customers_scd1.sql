-- ============================================================
-- Script:   01_sp_load_customers_scd1.sql
-- Purpose:  Incremental SCD Type 1 load: raw.customers -> staging.customers
-- Database: banking_delta (schemas: staging, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\staging\01_sp_load_customers_scd1.sql
--
-- Notes:
--   * Watermark comes from audit.etl_watermarks; NULL = bootstrap (load all).
--   * Watermark advances only on success, to max value processed.
--   * Overwritten values go to ONE shared table: staging.scd1_history
--     (all staging tables write there, keyed by table_name).
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('raw.customers') IS NULL THEN
        RAISE EXCEPTION 'raw.customers not found - land the source first.';
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
-- Target: current-state customer dimension (one row per customer)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.customers (
    customer_id      INTEGER       NOT NULL,
    customer_name    VARCHAR(200),
    gender           VARCHAR(10)   NOT NULL DEFAULT 'N/A',
    date_of_birth    DATE,
    city             VARCHAR(100),
    state            VARCHAR(100),
    phone            VARCHAR(10),
    email            VARCHAR(254),
    occupation       VARCHAR(100),
    annual_income    NUMERIC(12,2),
    join_date        DATE,
    credit_score     INTEGER,
    created_at       TIMESTAMP,
    loaded_at        TIMESTAMP,
    source_batch_id  TEXT,
    source_loaded_at TIMESTAMPTZ,
    row_added_at     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at   TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_customers PRIMARY KEY (customer_id),
    CONSTRAINT chk_customers_gender
        CHECK (gender IN ('Male', 'Female', 'N/A')),
    CONSTRAINT chk_customers_credit_score
        CHECK (credit_score IS NULL OR credit_score BETWEEN 300 AND 900),
    CONSTRAINT chk_customers_income
        CHECK (annual_income IS NULL OR annual_income >= 0)
);

COMMENT ON TABLE staging.customers IS
    'Cleaned customer dimension, SCD Type 1 (current state, overwritten in place).';

CREATE INDEX IF NOT EXISTS idx_customers_email
    ON staging.customers (email) WHERE email IS NOT NULL;

DROP TRIGGER IF EXISTS trg_customers_updated_at ON staging.customers;
CREATE TRIGGER trg_customers_updated_at
    BEFORE UPDATE ON staging.customers
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Shared SCD1 history (ONE table for all staging tables)
-- One row per changed column; table_name + record_key identify the row.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.scd1_history (
    history_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name       VARCHAR(128) NOT NULL,   -- e.g. 'staging.customers'
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
-- Seed watermark row for raw.customers (safe to re-run)
-- ------------------------------------------------------------
INSERT INTO audit.etl_watermarks (
    source_id, config_id, watermark_column, watermark_strategy
)
SELECT t.source_id, t.config_id, '_loaded_at', 'timestamp'
FROM audit.source_tables t
WHERE t.target_schema = 'raw'
  AND t.target_table  = 'customers'
ON CONFLICT (config_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL staging.sp_load_customers_scd1();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_load_customers_scd1(UUID, TEXT, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE staging.sp_load_customers_scd1(
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
            'raw.customers', 'staging.customers',
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
      AND t.target_table  = 'customers';

    IF v_config_id IS NULL THEN
        RAISE EXCEPTION 'raw.customers is not registered in audit.source_tables - run 03_register_sources.sql.';
    END IF;

    -- Read stored watermark config, then apply defaults / caller override
    SELECT w.watermark_column, w.watermark_strategy, w.last_watermark_value
    INTO v_wm_column, v_wm_strategy, v_last_wm
    FROM audit.etl_watermarks w
    WHERE w.config_id = v_config_id;

    v_wm_column   := COALESCE(p_watermark_column, v_wm_column, '_loaded_at');
    v_wm_strategy := COALESCE(v_wm_strategy, 'timestamp');

    IF v_wm_strategy NOT IN ('timestamp', 'numeric') THEN
        RAISE EXCEPTION 'Unsupported watermark_strategy % for raw.customers (use timestamp or numeric).', v_wm_strategy;
    END IF;

    -- Watermark column must exist on the source
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'customers'
          AND column_name  = v_wm_column
    ) THEN
        RAISE EXCEPTION 'Watermark column raw.customers.% does not exist.', v_wm_column;
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
    IF to_regclass('pg_temp._customers_src') IS NOT NULL THEN
        DROP TABLE _customers_src;
    END IF;

    -- Cleaned slice. Format args: (1) watermark column, (2) filter.
    -- Note: literal % in the regex must be written %% inside format().
    EXECUTE format($q$
        CREATE TEMP TABLE _customers_src ON COMMIT DROP AS
        WITH duplicate_filter AS (
            SELECT
                c.*,
                c.%I AS _wm_val,
                -- Filter first, then keep the LATEST row per customer
                ROW_NUMBER() OVER (
                    PARTITION BY c.customer_id
                    ORDER BY c._batch_id DESC, c._loaded_at DESC
                ) AS rnk
            FROM raw.customers c
            WHERE %s
        ),
        cleaned_base AS (
            SELECT
                customer_id::INT AS customer_id,
                NULLIF(TRIM(name), '')::VARCHAR AS customer_name,
                CASE
                    WHEN UPPER(TRIM(gender)) IN ('M', 'MALE')   THEN 'Male'
                    WHEN UPPER(TRIM(gender)) IN ('F', 'FEMALE') THEN 'Female'
                    ELSE 'N/A'
                END AS gender,
                CASE
                    WHEN TRIM(date_of_birth::TEXT) ~ '^\d{4}-\d{2}-\d{2}$'
                     AND TO_CHAR(
                            TO_DATE(TRIM(date_of_birth::TEXT), 'FXYYYY-MM-DD'),
                            'YYYY-MM-DD'
                         ) = TRIM(date_of_birth::TEXT)
                    THEN TO_DATE(TRIM(date_of_birth::TEXT), 'FXYYYY-MM-DD')
                    ELSE NULL
                END AS date_of_birth,
                INITCAP(NULLIF(TRIM(city), '')) AS city,
                INITCAP(NULLIF(TRIM(state), '')) AS state,
                CASE
                    WHEN TRIM(phone::TEXT) ~ '^[6-9][0-9]{9}$' THEN TRIM(phone::TEXT)
                    ELSE NULL
                END AS phone,
                CASE
                    WHEN LOWER(TRIM(email)) ~ '^[a-z0-9._%%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'
                        THEN LOWER(TRIM(email))
                    ELSE NULL
                END AS email,
                INITCAP(NULLIF(TRIM(occupation), '')) AS occupation,
                CASE
                    WHEN TRIM(annual_income::TEXT) ~ '^[0-9]+(\.[0-9]{1,2})?$'
                     AND TRIM(annual_income::TEXT)::NUMERIC >= 0
                    THEN TRIM(annual_income::TEXT)::NUMERIC
                    ELSE NULL
                END AS annual_income,
                CASE
                    WHEN TRIM(join_date::TEXT) ~ '^\d{4}-\d{2}-\d{2}$'
                     AND TO_CHAR(
                            TO_DATE(TRIM(join_date::TEXT), 'FXYYYY-MM-DD'),
                            'YYYY-MM-DD'
                         ) = TRIM(join_date::TEXT)
                    THEN TO_DATE(TRIM(join_date::TEXT), 'FXYYYY-MM-DD')
                    ELSE NULL
                END AS join_date,
                CASE
                    WHEN TRIM(credit_score::TEXT) ~ '^[0-9]+$'
                     AND TRIM(credit_score::TEXT)::INT BETWEEN 300 AND 900
                    THEN TRIM(credit_score::TEXT)::INT
                    ELSE NULL
                END AS credit_score,
                created_at,
                loaded_at,
                _batch_id,
                _loaded_at,
                f._wm_val AS wm_val
            FROM duplicate_filter f
            WHERE rnk = 1
        )
        SELECT
            cb.customer_id,
            cb.customer_name,
            cb.gender,
            cb.date_of_birth,
            cb.city,
            cb.state,
            cb.phone,
            cb.email,
            cb.occupation,
            cb.annual_income,
            cb.join_date,
            cb.credit_score,
            cb.created_at,
            cb.loaded_at,
            cb._batch_id  AS source_batch_id,
            cb._loaded_at AS source_loaded_at,
            cb.wm_val     AS wm_val
        FROM cleaned_base cb
        WHERE cb.customer_id IS NOT NULL
    $q$, v_wm_column, v_wm_cond);

    SELECT count(*) INTO v_source_rows FROM _customers_src;

    -- ===================== INSERT new customers =====================
    INSERT INTO staging.customers (
        customer_id,
        customer_name,
        gender,
        date_of_birth,
        city,
        state,
        phone,
        email,
        occupation,
        annual_income,
        join_date,
        credit_score,
        created_at,
        loaded_at,
        source_batch_id,
        source_loaded_at
    )
    SELECT
        s.customer_id,
        s.customer_name,
        s.gender,
        s.date_of_birth,
        s.city,
        s.state,
        s.phone,
        s.email,
        s.occupation,
        s.annual_income,
        s.join_date,
        s.credit_score,
        s.created_at,
        s.loaded_at,
        s.source_batch_id,
        s.source_loaded_at
    FROM _customers_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM staging.customers t
        WHERE t.customer_id = s.customer_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- History: one row per changed column, per customer (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'staging.customers',
        s.customer_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        s.source_batch_id,
        p_table_run_id
    FROM staging.customers t
    JOIN _customers_src s USING (customer_id)
    CROSS JOIN LATERAL (VALUES
        ('customer_name', t.customer_name::TEXT, s.customer_name::TEXT),
        ('gender',        t.gender::TEXT,        s.gender::TEXT),
        ('date_of_birth', t.date_of_birth::TEXT, s.date_of_birth::TEXT),
        ('city',          t.city::TEXT,          s.city::TEXT),
        ('state',         t.state::TEXT,         s.state::TEXT),
        ('phone',         t.phone::TEXT,         s.phone::TEXT),
        ('email',         t.email::TEXT,         s.email::TEXT),
        ('occupation',    t.occupation::TEXT,    s.occupation::TEXT),
        ('annual_income', t.annual_income::TEXT, s.annual_income::TEXT),
        ('join_date',     t.join_date::TEXT,     s.join_date::TEXT),
        ('credit_score',  t.credit_score::TEXT,  s.credit_score::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite only rows whose business columns changed
    UPDATE staging.customers t
    SET
        customer_name    = s.customer_name,
        gender           = s.gender,
        date_of_birth    = s.date_of_birth,
        city             = s.city,
        state            = s.state,
        phone            = s.phone,
        email            = s.email,
        occupation       = s.occupation,
        annual_income    = s.annual_income,
        join_date        = s.join_date,
        credit_score     = s.credit_score,
        created_at       = s.created_at,
        loaded_at        = s.loaded_at,
        source_batch_id  = s.source_batch_id,
        source_loaded_at = s.source_loaded_at
    FROM _customers_src s
    WHERE t.customer_id = s.customer_id
      AND ROW(
            t.customer_name, t.gender, t.date_of_birth, t.city, t.state,
            t.phone, t.email, t.occupation, t.annual_income, t.join_date,
            t.credit_score
      ) IS DISTINCT FROM ROW(
            s.customer_name, s.gender, s.date_of_birth, s.city, s.state,
            s.phone, s.email, s.occupation, s.annual_income, s.join_date,
            s.credit_score
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- Matched rows that were neither inserted nor updated
    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = typed max of the processed slice ----
    IF v_source_rows > 0 THEN
        SELECT max(wm_val)::TEXT INTO v_new_wm FROM _customers_src;
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
    RAISE NOTICE 'customers load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
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
        'raw.customers',
        'staging.customers',
        'staging',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'staging.sp_load_customers_scd1',
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
