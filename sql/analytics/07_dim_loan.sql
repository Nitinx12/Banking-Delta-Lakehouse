-- ============================================================
-- Script:   07_dim_loan.sql
-- Purpose:  Incremental SCD Type 1 load: staging.loans -> analytics.dim_loan
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\07_dim_loan.sql
-- Depends on: 01_dim_customer.sql, 03_dim_branch.sql (key lookups)
--
-- Notes:
--   * loan_key = surrogate key (facts store this); loan_id = natural key.
--   * customer_key / branch_key point to dim_customer / dim_branch
--     (-1 = Unknown), so loan payments can be analysed by customer and
--     branch attributes through the loan.
--   * The loan contract terms (amount, rate, term) live here as attributes:
--     staging holds one current row per loan, so there is no separate
--     "fact_loans". Payments go to fact_loan_payments.
--   * Derived: loan_amount_band (INR, adjust the cut-offs to your data),
--     term_band, start_year, maturity_date (start_date + term_months),
--     is_active.
--   * Late-arriving customer / branch: loans pointing at -1 are re-processed
--     automatically once the customer / branch exists in its dimension.
--   * Row -1 = 'Unknown' member, so facts never carry a NULL / broken key.
--   * Watermark = staging.loans.row_updated_at, stored on the dimension row
--     itself (source_row_updated_at). NULL = bootstrap (load all).
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.dim_loan').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.loans') IS NULL THEN
        RAISE EXCEPTION 'staging.loans not found - run 07_sp_load_loans_scd1.sql first.';
    END IF;

    IF to_regclass('staging.scd1_history') IS NULL THEN
        RAISE EXCEPTION 'staging.scd1_history not found - run 01_sp_load_customers_scd1.sql first.';
    END IF;

    IF to_regclass('analytics.dim_customer') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_customer not found - run 01_dim_customer.sql first.';
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
CREATE TABLE IF NOT EXISTS analytics.dim_loan (
    loan_key              INTEGER       GENERATED ALWAYS AS IDENTITY,   -- surrogate key
    loan_id               BIGINT        NOT NULL,                       -- natural key
    customer_key          INTEGER       NOT NULL DEFAULT -1,            -- -> dim_customer
    branch_key            INTEGER       NOT NULL DEFAULT -1,            -- -> dim_branch
    customer_id           INTEGER,                                      -- natural key of customer
    branch_id             INTEGER,                                      -- natural key of branch
    loan_type             VARCHAR(50)   NOT NULL DEFAULT 'Unknown',
    loan_amount           NUMERIC(14,2),
    loan_amount_band      VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived (INR)
    interest_rate         NUMERIC(7,4),
    term_months           INTEGER,
    term_band             VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived
    start_date            DATE,
    start_year            INTEGER,                                      -- derived
    maturity_date         DATE,                                         -- derived: start_date + term_months
    status                VARCHAR(30)   NOT NULL DEFAULT 'Unknown',
    is_active             BOOLEAN       NOT NULL DEFAULT FALSE,         -- derived: status = 'Active'
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_dim_loan PRIMARY KEY (loan_key),
    CONSTRAINT uq_dim_loan_id UNIQUE (loan_id),
    CONSTRAINT fk_dim_loan_customer
        FOREIGN KEY (customer_key) REFERENCES analytics.dim_customer (customer_key),
    CONSTRAINT fk_dim_loan_branch
        FOREIGN KEY (branch_key) REFERENCES analytics.dim_branch (branch_key)
);

COMMENT ON TABLE analytics.dim_loan IS
    'Loan dimension (SCD Type 1). Surrogate key loan_key; loan_key = -1 is the Unknown member. Holds loan terms; payments are in fact_loan_payments.';

CREATE INDEX IF NOT EXISTS idx_dim_loan_customer_key
    ON analytics.dim_loan (customer_key);

CREATE INDEX IF NOT EXISTS idx_dim_loan_branch_key
    ON analytics.dim_loan (branch_key);

DROP TRIGGER IF EXISTS trg_dim_loan_updated_at ON analytics.dim_loan;
CREATE TRIGGER trg_dim_loan_updated_at
    BEFORE UPDATE ON analytics.dim_loan
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Unknown member (facts with no matching loan point here)
-- ------------------------------------------------------------
INSERT INTO analytics.dim_loan (
    loan_key,
    loan_id,
    customer_key,
    branch_key,
    loan_type,
    loan_amount_band,
    term_band,
    status,
    is_active
)
OVERRIDING SYSTEM VALUE
VALUES (-1, -1, -1, -1, 'Unknown', 'Unknown', 'Unknown', 'Unknown', FALSE)
ON CONFLICT (loan_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL analytics.sp_load_dim_loan();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_dim_loan(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_dim_loan(
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
            'staging.loans',
            'analytics.dim_loan',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the dimension
    SELECT max(d.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.dim_loan d;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._dim_loan_src') IS NOT NULL THEN
        DROP TABLE _dim_loan_src;
    END IF;

    -- Slice of staging to process, with surrogate-key lookups and derived attributes
    CREATE TEMP TABLE _dim_loan_src ON COMMIT DROP AS
    SELECT
        l.loan_id,
        COALESCE(cu.customer_key, -1)               AS customer_key,
        COALESCE(b.branch_key, -1)                  AS branch_key,
        l.customer_id,
        l.branch_id,
        COALESCE(l.loan_type, 'Unknown')            AS loan_type,
        l.loan_amount,
        -- INR bands: adjust to your data
        CASE
            WHEN l.loan_amount IS NULL       THEN 'Unknown'
            WHEN l.loan_amount <    100000   THEN '<1L'
            WHEN l.loan_amount <    500000   THEN '1-5L'
            WHEN l.loan_amount <   2500000   THEN '5-25L'
            WHEN l.loan_amount <  10000000   THEN '25L-1Cr'
            ELSE '1Cr+'
        END                                         AS loan_amount_band,
        l.interest_rate,
        l.term_months,
        CASE
            WHEN l.term_months IS NULL  THEN 'Unknown'
            WHEN l.term_months <= 12    THEN '<=1 yr'
            WHEN l.term_months <= 60    THEN '1-5 yrs'
            WHEN l.term_months <= 180   THEN '5-15 yrs'
            ELSE '15+ yrs'
        END                                         AS term_band,
        l.start_date,
        EXTRACT(YEAR FROM l.start_date)::INT        AS start_year,
        CASE
            WHEN l.start_date IS NOT NULL AND l.term_months IS NOT NULL
            THEN (l.start_date + make_interval(months => l.term_months))::DATE
        END                                         AS maturity_date,
        COALESCE(l.status, 'Unknown')               AS status,
        COALESCE(l.status = 'Active', FALSE)        AS is_active,
        l.row_updated_at                            AS source_row_updated_at
    FROM staging.loans l
    LEFT JOIN analytics.dim_customer cu
           ON cu.customer_id = l.customer_id
    LEFT JOIN analytics.dim_branch b
           ON b.branch_id = l.branch_id
    LEFT JOIN analytics.dim_loan cur
           ON cur.loan_id = l.loan_id
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR l.row_updated_at > v_last_wm
       -- Late-arriving customer / branch: loan was loaded with Unknown, parent exists now
       OR (cur.customer_key = -1 AND cu.customer_key IS NOT NULL)
       OR (cur.branch_key   = -1 AND b.branch_key    IS NOT NULL);

    SELECT count(*) INTO v_source_rows FROM _dim_loan_src;

    -- ===================== INSERT new loans =====================
    INSERT INTO analytics.dim_loan (
        loan_id,
        customer_key,
        branch_key,
        customer_id,
        branch_id,
        loan_type,
        loan_amount,
        loan_amount_band,
        interest_rate,
        term_months,
        term_band,
        start_date,
        start_year,
        maturity_date,
        status,
        is_active,
        source_batch_id,
        source_row_updated_at
    )
    SELECT
        s.loan_id, s.customer_key, s.branch_key, s.customer_id, s.branch_id, s.loan_type,
        s.loan_amount, s.loan_amount_band, s.interest_rate, s.term_months, s.term_band,
        s.start_date, s.start_year, s.maturity_date, s.status, s.is_active,
        p_source_batch_id, s.source_row_updated_at
    FROM _dim_loan_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.dim_loan d
        WHERE d.loan_id = s.loan_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- History: one row per changed column, per loan (must run before UPDATE)
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
        'analytics.dim_loan',
        s.loan_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.dim_loan d
    JOIN _dim_loan_src s USING (loan_id)
    CROSS JOIN LATERAL (VALUES
        ('customer_key',     d.customer_key::TEXT,     s.customer_key::TEXT),
        ('branch_key',       d.branch_key::TEXT,       s.branch_key::TEXT),
        ('customer_id',      d.customer_id::TEXT,      s.customer_id::TEXT),
        ('branch_id',        d.branch_id::TEXT,        s.branch_id::TEXT),
        ('loan_type',        d.loan_type::TEXT,        s.loan_type::TEXT),
        ('loan_amount',      d.loan_amount::TEXT,      s.loan_amount::TEXT),
        ('loan_amount_band', d.loan_amount_band::TEXT, s.loan_amount_band::TEXT),
        ('interest_rate',    d.interest_rate::TEXT,    s.interest_rate::TEXT),
        ('term_months',      d.term_months::TEXT,      s.term_months::TEXT),
        ('term_band',        d.term_band::TEXT,        s.term_band::TEXT),
        ('start_date',       d.start_date::TEXT,       s.start_date::TEXT),
        ('start_year',       d.start_year::TEXT,       s.start_year::TEXT),
        ('maturity_date',    d.maturity_date::TEXT,    s.maturity_date::TEXT),
        ('status',           d.status::TEXT,           s.status::TEXT),
        ('is_active',        d.is_active::TEXT,        s.is_active::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.dim_loan d
    SET
        customer_key          = s.customer_key,
        branch_key            = s.branch_key,
        customer_id           = s.customer_id,
        branch_id             = s.branch_id,
        loan_type             = s.loan_type,
        loan_amount           = s.loan_amount,
        loan_amount_band      = s.loan_amount_band,
        interest_rate         = s.interest_rate,
        term_months           = s.term_months,
        term_band             = s.term_band,
        start_date            = s.start_date,
        start_year            = s.start_year,
        maturity_date         = s.maturity_date,
        status                = s.status,
        is_active             = s.is_active,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _dim_loan_src s
    WHERE d.loan_id = s.loan_id
      AND ROW(
            d.customer_key, d.branch_key, d.customer_id, d.branch_id, d.loan_type,
            d.loan_amount, d.loan_amount_band, d.interest_rate, d.term_months, d.term_band,
            d.start_date, d.start_year, d.maturity_date, d.status, d.is_active,
            d.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.customer_key, s.branch_key, s.customer_id, s.branch_id, s.loan_type,
            s.loan_amount, s.loan_amount_band, s.interest_rate, s.term_months, s.term_band,
            s.start_date, s.start_year, s.maturity_date, s.status, s.is_active,
            s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _dim_loan_src;
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
            'watermark_column',   'staging.loans.row_updated_at',
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
    RAISE NOTICE 'dim_loan load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
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
        'staging.loans',
        'analytics.dim_loan',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'analytics.sp_load_dim_loan',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', 'staging.loans.row_updated_at'
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
CALL analytics.sp_load_dim_loan();
