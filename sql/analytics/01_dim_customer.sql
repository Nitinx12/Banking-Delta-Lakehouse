-- ============================================================
-- Script:   01_dim_customer.sql
-- Purpose:  Incremental SCD Type 1 load: staging.customers -> analytics.dim_customer
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\01_dim_customer.sql
--
-- Notes:
--   * Dimension = descriptive attributes used to filter / group facts.
--   * customer_key = surrogate key (facts store this); customer_id = natural key.
--   * Row -1 = 'Unknown' member, so facts never carry a NULL / broken key.
--   * Watermark = staging.customers.row_updated_at, stored on the dimension row
--     itself (source_row_updated_at). NULL = bootstrap (load all).
--     Because it lives in the target, it advances only if the load commits.
--   * Derived bands (age_band) can drift with time (birthdays); use
--     p_force_full = TRUE to refresh them across all customers.
--   * Gender fix: gender is corrected from the first name using a name list
--     written inline in the procedure (CTE "ng"); no extra table needed.
--     Unisex / unlisted names keep the staging gender. After adding names
--     to the list, run with p_force_full = TRUE so existing customers are
--     re-evaluated.
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.dim_customer').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.customers') IS NULL THEN
        RAISE EXCEPTION 'staging.customers not found - run 01_sp_load_customers_scd1.sql first.';
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
CREATE TABLE IF NOT EXISTS analytics.dim_customer (
    customer_key          INTEGER       GENERATED ALWAYS AS IDENTITY,   -- surrogate key
    customer_id           INTEGER       NOT NULL,                       -- natural key
    customer_name         VARCHAR(200),
    gender                VARCHAR(10)   NOT NULL DEFAULT 'N/A',
    date_of_birth         DATE,
    age_band              VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived
    city                  VARCHAR(100),
    state                 VARCHAR(100),
    phone                 VARCHAR(10),
    email                 VARCHAR(254),
    occupation            VARCHAR(100),
    annual_income         NUMERIC(12,2),
    income_band           VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived
    join_date             DATE,
    credit_score          INTEGER,
    credit_band           VARCHAR(20)   NOT NULL DEFAULT 'Unknown',     -- derived
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_dim_customer PRIMARY KEY (customer_key),
    CONSTRAINT uq_dim_customer_id UNIQUE (customer_id)
);

-- In case an earlier version of this table already exists
ALTER TABLE analytics.dim_customer ADD COLUMN IF NOT EXISTS source_batch_id TEXT;
ALTER TABLE analytics.dim_customer ADD COLUMN IF NOT EXISTS source_row_updated_at TIMESTAMPTZ;

COMMENT ON TABLE analytics.dim_customer IS
    'Customer dimension (SCD Type 1). Surrogate key customer_key; customer_key = -1 is the Unknown member.';

CREATE INDEX IF NOT EXISTS idx_dim_customer_state_city
    ON analytics.dim_customer (state, city);

DROP TRIGGER IF EXISTS trg_dim_customer_updated_at ON analytics.dim_customer;
CREATE TRIGGER trg_dim_customer_updated_at
    BEFORE UPDATE ON analytics.dim_customer
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Unknown member (facts with no matching customer point here)
-- ------------------------------------------------------------
INSERT INTO analytics.dim_customer (
    customer_key, customer_id, customer_name, gender,
    age_band, income_band, credit_band
)
OVERRIDING SYSTEM VALUE
VALUES (-1, -1, 'Unknown', 'N/A', 'Unknown', 'Unknown', 'Unknown')
ON CONFLICT (customer_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL analytics.sp_load_dim_customer();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_dim_customer(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_dim_customer(
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
            'staging.customers', 'analytics.dim_customer',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the dimension
    SELECT max(d.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.dim_customer d;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._dim_customer_src') IS NOT NULL THEN
        DROP TABLE _dim_customer_src;
    END IF;

    -- Slice of staging to process, with derived attributes
    CREATE TEMP TABLE _dim_customer_src ON COMMIT DROP AS
    WITH ng (first_name_key, ref_gender) AS (
        VALUES
            -- Female
            ('pooja','Female'),('anjali','Female'),('priya','Female'),('neha','Female'),
            ('sneha','Female'),('kavita','Female'),('sunita','Female'),('anita','Female'),
            ('rekha','Female'),('meena','Female'),('geeta','Female'),('sita','Female'),
            ('radha','Female'),('lakshmi','Female'),('deepika','Female'),('shreya','Female'),
            ('divya','Female'),('nisha','Female'),('swati','Female'),('ritu','Female'),
            ('pallavi','Female'),('aarti','Female'),('anjana','Female'),('manisha','Female'),
            ('shweta','Female'),('preeti','Female'),('sonia','Female'),('komal','Female'),
            ('isha','Female'),('ananya','Female'),('aditi','Female'),('riya','Female'),
            ('simran','Female'),('nidhi','Female'),('payal','Female'),('rashmi','Female'),
            ('madhuri','Female'),('sakshi','Female'),('tanvi','Female'),('meera','Female'),
            ('jyoti','Female'),('seema','Female'),('usha','Female'),('kriti','Female'),
            ('mansi','Female'),('bhavna','Female'),('vandana','Female'),('shilpa','Female'),
            ('archana','Female'),('sapna','Female'),('namita','Female'),('poonam','Female'),
            ('kajal','Female'),('ritika','Female'),('shalini','Female'),('parul','Female'),
            ('garima','Female'),
            -- Male
            ('rahul','Male'),('amit','Male'),('rohit','Male'),('vikram','Male'),
            ('sanjay','Male'),('rajesh','Male'),('suresh','Male'),('ramesh','Male'),
            ('manoj','Male'),('anil','Male'),('sunil','Male'),('vijay','Male'),
            ('ajay','Male'),('arjun','Male'),('karan','Male'),('vivek','Male'),
            ('nikhil','Male'),('ankit','Male'),('gaurav','Male'),('deepak','Male'),
            ('mohit','Male'),('sachin','Male'),('ashok','Male'),('pankaj','Male'),
            ('rakesh','Male'),('naveen','Male'),('harish','Male'),('mahesh','Male'),
            ('dinesh','Male'),('prakash','Male'),('sandeep','Male'),('varun','Male'),
            ('aditya','Male'),('siddharth','Male'),('abhishek','Male'),('akash','Male'),
            ('yash','Male'),('kunal','Male'),('tarun','Male'),('manish','Male'),
            ('pradeep','Male'),('ravi','Male'),('sumit','Male'),('vishal','Male'),
            ('hemant','Male'),('mukesh','Male'),('neeraj','Male'),('rajat','Male'),
            ('saurabh','Male'),('tushar','Male'),('ishaan','Male'),('aryan','Male'),
            ('rohan','Male'),('kabir','Male')
    )
    SELECT
        c.customer_id,
        c.customer_name,
        -- Gender fix: if the first name is in the inline name list (ng), it wins over
        -- the staging value; unlisted names keep the staging gender.
        COALESCE(g.ref_gender, c.gender, 'N/A') AS gender,
        c.date_of_birth,
        CASE
            WHEN c.date_of_birth IS NULL THEN 'Unknown'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, c.date_of_birth)) < 25 THEN '18-24'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, c.date_of_birth)) < 35 THEN '25-34'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, c.date_of_birth)) < 45 THEN '35-44'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, c.date_of_birth)) < 55 THEN '45-54'
            WHEN DATE_PART('year', AGE(CURRENT_DATE, c.date_of_birth)) < 65 THEN '55-64'
            ELSE '65+'
        END AS age_band,
        c.city,
        c.state,
        c.phone,
        c.email,
        c.occupation,
        c.annual_income,
        -- INR bands: adjust to your data
        CASE
            WHEN c.annual_income IS NULL   THEN 'Unknown'
            WHEN c.annual_income <  300000 THEN 'Low (<3L)'
            WHEN c.annual_income <  600000 THEN 'Lower-Mid (3-6L)'
            WHEN c.annual_income < 1200000 THEN 'Middle (6-12L)'
            WHEN c.annual_income < 2400000 THEN 'Upper-Mid (12-24L)'
            ELSE 'High (24L+)'
        END AS income_band,
        c.join_date,
        c.credit_score,
        CASE
            WHEN c.credit_score IS NULL THEN 'Unknown'
            WHEN c.credit_score < 550   THEN 'Poor'
            WHEN c.credit_score < 650   THEN 'Fair'
            WHEN c.credit_score < 750   THEN 'Good'
            ELSE 'Excellent'
        END AS credit_band,
        c.row_updated_at AS source_row_updated_at
    FROM staging.customers c
    LEFT JOIN ng g
           ON g.first_name_key = LOWER(SPLIT_PART(TRIM(c.customer_name), ' ', 1))
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR c.row_updated_at > v_last_wm;

    SELECT count(*) INTO v_source_rows FROM _dim_customer_src;

    -- ===================== INSERT new customers =====================
    INSERT INTO analytics.dim_customer (
        customer_id,
        customer_name,
        gender,
        date_of_birth,
        age_band,
        city,
        state,
        phone,
        email,
        occupation,
        annual_income,
        income_band,
        join_date,
        credit_score,
        credit_band,
        source_batch_id,
        source_row_updated_at
    )
    SELECT
        s.customer_id,
        s.customer_name,
        s.gender,
        s.date_of_birth,
        s.age_band,
        s.city,
        s.state,
        s.phone,
        s.email,
        s.occupation,
        s.annual_income,
        s.income_band,
        s.join_date,
        s.credit_score,
        s.credit_band,
        p_source_batch_id,
        s.source_row_updated_at
    FROM _dim_customer_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.dim_customer d
        WHERE d.customer_id = s.customer_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- History: one row per changed column, per customer (must run before UPDATE)
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
        'analytics.dim_customer',
        s.customer_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.dim_customer d
    JOIN _dim_customer_src s USING (customer_id)
    CROSS JOIN LATERAL (VALUES
        ('customer_name', d.customer_name::TEXT, s.customer_name::TEXT),
        ('gender',        d.gender::TEXT,        s.gender::TEXT),
        ('date_of_birth', d.date_of_birth::TEXT, s.date_of_birth::TEXT),
        ('age_band',      d.age_band::TEXT,      s.age_band::TEXT),
        ('city',          d.city::TEXT,          s.city::TEXT),
        ('state',         d.state::TEXT,         s.state::TEXT),
        ('phone',         d.phone::TEXT,         s.phone::TEXT),
        ('email',         d.email::TEXT,         s.email::TEXT),
        ('occupation',    d.occupation::TEXT,    s.occupation::TEXT),
        ('annual_income', d.annual_income::TEXT, s.annual_income::TEXT),
        ('income_band',   d.income_band::TEXT,   s.income_band::TEXT),
        ('join_date',     d.join_date::TEXT,     s.join_date::TEXT),
        ('credit_score',  d.credit_score::TEXT,  s.credit_score::TEXT),
        ('credit_band',   d.credit_band::TEXT,   s.credit_band::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.dim_customer d
    SET
        customer_name         = s.customer_name,
        gender                = s.gender,
        date_of_birth         = s.date_of_birth,
        age_band              = s.age_band,
        city                  = s.city,
        state                 = s.state,
        phone                 = s.phone,
        email                 = s.email,
        occupation            = s.occupation,
        annual_income         = s.annual_income,
        income_band           = s.income_band,
        join_date             = s.join_date,
        credit_score          = s.credit_score,
        credit_band           = s.credit_band,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _dim_customer_src s
    WHERE d.customer_id = s.customer_id
      AND ROW(
            d.customer_name, d.gender,
            d.date_of_birth, d.age_band,
            d.city, d.state,
            d.phone, d.email,
            d.occupation, d.annual_income,
            d.income_band, d.join_date,
            d.credit_score, d.credit_band,
            d.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.customer_name, s.gender,
            s.date_of_birth, s.age_band,
            s.city, s.state,
            s.phone, s.email,
            s.occupation, s.annual_income,
            s.income_band, s.join_date,
            s.credit_score, s.credit_band,
            s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _dim_customer_src;
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
            'watermark_column',   'staging.customers.row_updated_at',
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
    RAISE NOTICE 'dim_customer load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
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
        'staging.customers',
        'analytics.dim_customer',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',       'analytics.sp_load_dim_customer',
            'source_batch_id', p_source_batch_id,
            'watermark_column', 'staging.customers.row_updated_at'
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
CALL analytics.sp_load_dim_customer();
