-- ============================================================
-- Script:   04_dim_employee.sql
-- Purpose:  Incremental SCD Type 1 load: staging.employees -> analytics.dim_employee
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\04_dim_employee.sql
-- Depends on: 03_dim_branch.sql (branch_key lookup)
--
-- Notes:
--   * employee_key = surrogate key; employee_id = natural key.
--   * branch_key   = surrogate key of the employee's branch in analytics.dim_branch
--     (-1 = Unknown branch).
--   * salary is kept as an attribute because there is no payroll fact yet.
--     If you later build a payroll fact, move salary there.
--   * tenure_band drifts with time; use p_force_full = TRUE to refresh it.
--   * Late-arriving branches: employees pointing at branch_key = -1 are
--     re-processed automatically once their branch exists in dim_branch.
--   * Row -1 = 'Unknown' member, so facts never carry a NULL / broken key.
--   * Watermark = staging.employees.row_updated_at, stored on the dimension row
--     itself (source_row_updated_at). NULL = bootstrap (load all).
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.dim_employee').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.employees') IS NULL THEN
        RAISE EXCEPTION 'staging.employees not found - run 04_sp_load_employees_scd1.sql first.';
    END IF;

    IF to_regclass('staging.scd1_history') IS NULL THEN
        RAISE EXCEPTION 'staging.scd1_history not found - run 01_sp_load_customers_scd1.sql first.';
    END IF;

    IF to_regclass('analytics.dim_branch') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_branch not found - run 03_dim_branch.sql first.';
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
CREATE TABLE IF NOT EXISTS analytics.dim_employee (
    employee_key          INTEGER       GENERATED ALWAYS AS IDENTITY,   -- surrogate key
    employee_id           INTEGER       NOT NULL,                       -- natural key
    employee_name         VARCHAR(200),
    branch_key            INTEGER       NOT NULL DEFAULT -1,            -- -> dim_branch
    branch_id             INTEGER,                                      -- natural key of branch
    role                  VARCHAR(100)  NOT NULL DEFAULT 'Unknown',
    hire_date             DATE,
    hire_year             INTEGER,                                      -- derived
    tenure_band           VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived
    salary                NUMERIC(12,2),
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_dim_employee PRIMARY KEY (employee_key),
    CONSTRAINT uq_dim_employee_id UNIQUE (employee_id),
    CONSTRAINT fk_dim_employee_branch
        FOREIGN KEY (branch_key) REFERENCES analytics.dim_branch (branch_key)
);

COMMENT ON TABLE analytics.dim_employee IS
    'Employee dimension (SCD Type 1). Surrogate key employee_key; employee_key = -1 is the Unknown member.';

CREATE INDEX IF NOT EXISTS idx_dim_employee_branch_key
    ON analytics.dim_employee (branch_key);

DROP TRIGGER IF EXISTS trg_dim_employee_updated_at ON analytics.dim_employee;
CREATE TRIGGER trg_dim_employee_updated_at
    BEFORE UPDATE ON analytics.dim_employee
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Unknown member (facts with no matching employee point here)
-- ------------------------------------------------------------
INSERT INTO analytics.dim_employee (
    employee_key, employee_id, employee_name, branch_key, role, tenure_band
)
OVERRIDING SYSTEM VALUE
VALUES (-1, -1, 'Unknown', -1, 'Unknown', 'Unknown')
ON CONFLICT (employee_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL analytics.sp_load_dim_employee();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_dim_employee(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_dim_employee(
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
            'staging.employees', 'analytics.dim_employee',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the dimension
    SELECT max(d.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.dim_employee d;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._dim_employee_src') IS NOT NULL THEN
        DROP TABLE _dim_employee_src;
    END IF;

    -- Slice of staging to process, with surrogate-key lookup and derived attributes
    CREATE TEMP TABLE _dim_employee_src ON COMMIT DROP AS
    SELECT
        e.employee_id,
        e.employee_name,
        COALESCE(b.branch_key, -1)              AS branch_key,
        e.branch_id,
        COALESCE(e.role, 'Unknown')             AS role,
        e.hire_date,
        EXTRACT(YEAR FROM e.hire_date)::INT     AS hire_year,
        CASE
            WHEN e.hire_date IS NULL THEN 'Unknown'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, e.hire_date)) < 1  THEN '<1 yr'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, e.hire_date)) < 3  THEN '1-3 yrs'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, e.hire_date)) < 5  THEN '3-5 yrs'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, e.hire_date)) < 10 THEN '5-10 yrs'
            ELSE '10+ yrs'
        END                                     AS tenure_band,
        e.salary,
        e.row_updated_at                        AS source_row_updated_at
    FROM staging.employees e
    LEFT JOIN analytics.dim_branch b
           ON b.branch_id = e.branch_id
    LEFT JOIN analytics.dim_employee cur
           ON cur.employee_id = e.employee_id
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR e.row_updated_at > v_last_wm
       -- Late-arriving branch: employee was loaded with Unknown branch, branch exists now
       OR (cur.branch_key = -1 AND b.branch_key IS NOT NULL);

    SELECT count(*) INTO v_source_rows FROM _dim_employee_src;

    -- ===================== INSERT new employees =====================
    INSERT INTO analytics.dim_employee (
        employee_id, employee_name, branch_key, branch_id, role,
        hire_date, hire_year, tenure_band, salary,
        source_batch_id, source_row_updated_at
    )
    SELECT
        s.employee_id, s.employee_name, s.branch_key, s.branch_id, s.role,
        s.hire_date, s.hire_year, s.tenure_band, s.salary,
        p_source_batch_id, s.source_row_updated_at
    FROM _dim_employee_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.dim_employee d
        WHERE d.employee_id = s.employee_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- History: one row per changed column, per employee (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'analytics.dim_employee',
        s.employee_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.dim_employee d
    JOIN _dim_employee_src s USING (employee_id)
    CROSS JOIN LATERAL (VALUES
        ('employee_name', d.employee_name::TEXT, s.employee_name::TEXT),
        ('branch_key',    d.branch_key::TEXT,    s.branch_key::TEXT),
        ('branch_id',     d.branch_id::TEXT,     s.branch_id::TEXT),
        ('role',          d.role::TEXT,          s.role::TEXT),
        ('hire_date',     d.hire_date::TEXT,     s.hire_date::TEXT),
        ('hire_year',     d.hire_year::TEXT,     s.hire_year::TEXT),
        ('tenure_band',   d.tenure_band::TEXT,   s.tenure_band::TEXT),
        ('salary',        d.salary::TEXT,        s.salary::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.dim_employee d
    SET
        employee_name         = s.employee_name,
        branch_key            = s.branch_key,
        branch_id             = s.branch_id,
        role                  = s.role,
        hire_date             = s.hire_date,
        hire_year             = s.hire_year,
        tenure_band           = s.tenure_band,
        salary                = s.salary,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _dim_employee_src s
    WHERE d.employee_id = s.employee_id
      AND ROW(
            d.employee_name, d.branch_key, d.branch_id, d.role, d.hire_date,
            d.hire_year, d.tenure_band, d.salary, d.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.employee_name, s.branch_key, s.branch_id, s.role, s.hire_date,
            s.hire_year, s.tenure_band, s.salary, s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _dim_employee_src;
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
            'watermark_column',   'staging.employees.row_updated_at',
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
    RAISE NOTICE 'dim_employee load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
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
        'staging.employees',
        'analytics.dim_employee',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'analytics.sp_load_dim_employee',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', 'staging.employees.row_updated_at'
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
CALL analytics.sp_load_dim_employee();
