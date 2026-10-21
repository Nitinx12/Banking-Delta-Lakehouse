-- ============================================================
-- Script:   03_dim_branch.sql
-- Purpose:  Incremental SCD Type 1 load: staging.branches -> analytics.dim_branch
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\03_dim_branch.sql
--
-- Notes:
--   * branch_key = surrogate key (facts / dim_account store this);
--     branch_id  = natural key from the source system.
--   * region is derived from state (North / South / East / West / Central /
--     Northeast) so branches can be rolled up above state level. The state
--     list is inline in the procedure; edit it there and run with
--     p_force_full = TRUE.
--   * branch_age_band ages with time; rows whose stored band no longer
--     matches today's recomputation are re-picked on every run.
--   * Row -1 = 'Unknown' member, so facts never carry a NULL / broken key.
--   * Watermark = staging.branches.row_updated_at, stored on the dimension row
--     itself (source_row_updated_at). NULL = bootstrap (load all).
--     Because it lives in the target, it advances only if the load commits.
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.dim_branch').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.branches') IS NULL THEN
        RAISE EXCEPTION 'staging.branches not found - run 03_sp_load_branches_scd1.sql first.';
    END IF;

    IF to_regclass('staging.scd1_history') IS NULL THEN
        RAISE EXCEPTION 'staging.scd1_history not found - run 01_sp_load_customers_scd1.sql first.';
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
CREATE TABLE IF NOT EXISTS analytics.dim_branch (
    branch_key            INTEGER       GENERATED ALWAYS AS IDENTITY,   -- surrogate key
    branch_id             INTEGER       NOT NULL,                       -- natural key
    branch_name           VARCHAR(200),
    city                  VARCHAR(100),
    state                 VARCHAR(100),
    region                VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived from state
    ifsc_code             VARCHAR(11),
    opened_date           DATE,
    opened_year           INTEGER,                                      -- derived
    branch_age_band       VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_dim_branch PRIMARY KEY (branch_key),
    CONSTRAINT uq_dim_branch_id UNIQUE (branch_id)
);

COMMENT ON TABLE analytics.dim_branch IS
    'Branch dimension (SCD Type 1). Surrogate key branch_key; branch_key = -1 is the Unknown member.';

CREATE INDEX IF NOT EXISTS idx_dim_branch_region_state_city
    ON analytics.dim_branch (region, state, city);

DROP TRIGGER IF EXISTS trg_dim_branch_updated_at ON analytics.dim_branch;
CREATE TRIGGER trg_dim_branch_updated_at
    BEFORE UPDATE ON analytics.dim_branch
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Unknown member (facts with no matching branch point here)
-- ------------------------------------------------------------
INSERT INTO analytics.dim_branch (
    branch_key,
    branch_id,
    branch_name,
    region,
    branch_age_band
)
OVERRIDING SYSTEM VALUE
VALUES (-1, -1, 'Unknown', 'Unknown', 'Unknown')
ON CONFLICT (branch_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL analytics.sp_load_dim_branch();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_dim_branch(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_dim_branch(
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
            'staging.branches', 'analytics.dim_branch',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the dimension
    SELECT max(d.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.dim_branch d;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._dim_branch_src') IS NOT NULL THEN
        DROP TABLE _dim_branch_src;
    END IF;

    -- Slice of staging to process, with derived attributes
    CREATE TEMP TABLE _dim_branch_src ON COMMIT DROP AS
    SELECT s.*
    FROM (
        SELECT
            b.branch_id,
            b.branch_name,
            b.city,
            b.state,
            -- Region roll-up from state (edit the lists to suit your data)
            CASE
                WHEN b.state IS NULL THEN 'Unknown'
                WHEN LOWER(b.state) IN (
                     'delhi', 'haryana', 'punjab', 'himachal pradesh', 'uttarakhand',
                     'uttar pradesh', 'jammu and kashmir',
                     'chandigarh', 'ladakh', 'rajasthan')                 THEN 'North'
                WHEN LOWER(b.state) IN (
                     'karnataka', 'tamil nadu', 'kerala', 'andhra pradesh',
                     'telangana', 'puducherry')                           THEN 'South'
                WHEN LOWER(b.state) IN (
                     'west bengal', 'odisha', 'bihar', 'jharkhand')       THEN 'East'
                WHEN LOWER(b.state) IN (
                     'maharashtra', 'gujarat', 'goa')                     THEN 'West'
                WHEN LOWER(b.state) IN (
                     'madhya pradesh', 'chhattisgarh')                    THEN 'Central'
                WHEN LOWER(b.state) IN (
                     'assam', 'meghalaya', 'manipur', 'mizoram', 'nagaland',
                     'tripura', 'arunachal pradesh', 'sikkim')            THEN 'Northeast'
                ELSE 'Other'
            END AS region,
            b.ifsc_code,
            b.opened_date,
            EXTRACT(YEAR FROM b.opened_date)::INT AS opened_year,
            CASE
                WHEN b.opened_date IS NULL THEN 'Unknown'
                WHEN DATE_PART('year', AGE(CURRENT_DATE, b.opened_date)) < 2  THEN '<2 yrs'
                WHEN DATE_PART('year', AGE(CURRENT_DATE, b.opened_date)) < 5  THEN '2-5 yrs'
                WHEN DATE_PART('year', AGE(CURRENT_DATE, b.opened_date)) < 10 THEN '5-10 yrs'
                ELSE '10+ yrs'
            END AS branch_age_band,
            b.row_updated_at AS source_row_updated_at
        FROM staging.branches b
    ) s
    LEFT JOIN analytics.dim_branch cur
           ON cur.branch_id = s.branch_id
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR s.source_row_updated_at > v_last_wm
       -- branch_age_band ages with time; re-pick rows whose stored band drifted
       OR s.branch_age_band IS DISTINCT FROM cur.branch_age_band;

    SELECT count(*) INTO v_source_rows FROM _dim_branch_src;

    -- ===================== INSERT new branches =====================
    INSERT INTO analytics.dim_branch (
        branch_id,
        branch_name,
        city,
        state,
        region,
        ifsc_code,
        opened_date,
        opened_year,
        branch_age_band,
        source_batch_id,
        source_row_updated_at
    )
    SELECT
        s.branch_id, s.branch_name, s.city, s.state, s.region, s.ifsc_code,
        s.opened_date, s.opened_year, s.branch_age_band,
        p_source_batch_id, s.source_row_updated_at
    FROM _dim_branch_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.dim_branch d
        WHERE d.branch_id = s.branch_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- History: one row per changed column, per branch (must run before UPDATE)
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
        'analytics.dim_branch',
        s.branch_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.dim_branch d
    JOIN _dim_branch_src s USING (branch_id)
    CROSS JOIN LATERAL (VALUES
        ('branch_name',     d.branch_name::TEXT,     s.branch_name::TEXT),
        ('city',            d.city::TEXT,            s.city::TEXT),
        ('state',           d.state::TEXT,           s.state::TEXT),
        ('region',          d.region::TEXT,          s.region::TEXT),
        ('ifsc_code',       d.ifsc_code::TEXT,       s.ifsc_code::TEXT),
        ('opened_date',     d.opened_date::TEXT,     s.opened_date::TEXT),
        ('opened_year',     d.opened_year::TEXT,     s.opened_year::TEXT),
        ('branch_age_band', d.branch_age_band::TEXT, s.branch_age_band::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.dim_branch d
    SET
        branch_name           = s.branch_name,
        city                  = s.city,
        state                 = s.state,
        region                = s.region,
        ifsc_code             = s.ifsc_code,
        opened_date           = s.opened_date,
        opened_year           = s.opened_year,
        branch_age_band       = s.branch_age_band,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _dim_branch_src s
    WHERE d.branch_id = s.branch_id
      AND ROW(
            d.branch_name, d.city, d.state, d.region, d.ifsc_code,
            d.opened_date, d.opened_year, d.branch_age_band,
            d.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.branch_name, s.city, s.state, s.region, s.ifsc_code,
            s.opened_date, s.opened_year, s.branch_age_band,
            s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _dim_branch_src;
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
            'watermark_column',   'staging.branches.row_updated_at',
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
    RAISE NOTICE 'dim_branch load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
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
        'staging.branches',
        'analytics.dim_branch',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'analytics.sp_load_dim_branch',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', 'staging.branches.row_updated_at'
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
CALL analytics.sp_load_dim_branch();
