-- ============================================================
-- Script:   07_sp_load_loans_scd1.sql
-- Purpose:  Incremental SCD Type 1 load: raw.loans -> staging.loans
-- Database: banking_delta (schemas: staging, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\staging\07_sp_load_loans_scd1.sql
--
-- Notes:
--   * Watermark comes from audit.etl_watermarks; NULL = bootstrap (load all).
--   * Watermark advances only on success, to max value processed.
--   * Overwritten values go to the shared staging.scd1_history.
--
-- Cleaning rules (invalid value -> NULL, row is kept):
--   loan_id        digits only, 1-18 long (invalid -> row dropped)
--   customer_id    digits only, 1-9 long
--   branch_id      digits only, 1-9 long
--   loan_type      trimmed, spaces/underscores/hyphens collapsed, Title Case,
--                  must be one of: Home Loan, Gold Loan, Personal Loan,
--                  Education Loan, Auto Loan, Business Loan
--   loan_amount    numeric, up to 2 decimals, greater than 0
--   interest_rate  numeric, up to 4 decimals, greater than 0 and at most 100
--   term_months    whole number, 1 to 600
--   start_date     valid date (time part ignored), not in the future,
--                  not before 2000-01-01
--   status         trimmed, spaces/underscores/hyphens collapsed, Title Case,
--                  must be one of: Active, Closed, Written Off, Defaulted
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('raw.loans') IS NULL THEN
        RAISE EXCEPTION 'raw.loans not found - land the source first.';
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
-- Strict: rejects 2023-02-30 AND zero month/day (TO_DATE would turn
-- 2024-00-15 into 2024-01-15). No exception handling, so it stays
-- fast on millions of rows. Same definition in every script.
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

    -- Days in month (leap-year aware)
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
    table_name       VARCHAR(128) NOT NULL,   -- e.g. 'staging.loans'
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
-- Target: current-state loans (one row per loan)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.loans (
    loan_id           BIGINT        NOT NULL,
    customer_id       INTEGER,
    branch_id         INTEGER,
    loan_type         VARCHAR(50),
    loan_amount       NUMERIC(14,2),
    interest_rate     NUMERIC(7,4),
    term_months       INTEGER,
    start_date        DATE,
    status            VARCHAR(30),
    created_at        TIMESTAMP,
    loaded_at         TIMESTAMP,
    source_batch_id   TEXT,
    source_loaded_at  TIMESTAMPTZ,
    row_added_at      TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at    TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_loans PRIMARY KEY (loan_id),
    CONSTRAINT chk_loans_amount
        CHECK (loan_amount IS NULL OR loan_amount > 0),
    CONSTRAINT chk_loans_interest_rate
        CHECK (interest_rate IS NULL OR interest_rate > 0 AND interest_rate <= 100),
    CONSTRAINT chk_loans_term_months
        CHECK (term_months IS NULL OR term_months BETWEEN 1 AND 600)
);

COMMENT ON TABLE staging.loans IS
    'Cleaned loans, SCD Type 1 (current state, overwritten in place).';

CREATE INDEX IF NOT EXISTS idx_loans_customer
    ON staging.loans (customer_id);

CREATE INDEX IF NOT EXISTS idx_loans_branch
    ON staging.loans (branch_id);

DROP TRIGGER IF EXISTS trg_loans_updated_at ON staging.loans;
CREATE TRIGGER trg_loans_updated_at
    BEFORE UPDATE ON staging.loans
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

-- ------------------------------------------------------------
-- Seed watermark row for raw.loans (safe to re-run)
-- ------------------------------------------------------------
INSERT INTO audit.etl_watermarks (
    source_id, config_id, watermark_column, watermark_strategy
)
SELECT t.source_id, t.config_id, '_loaded_at', 'timestamp'
FROM audit.source_tables t
WHERE t.target_schema = 'raw'
  AND t.target_table  = 'loans'
ON CONFLICT (config_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL staging.sp_load_loans_scd1();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- work_mem applies only while this procedure runs.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE staging.sp_load_loans_scd1(
    IN p_table_run_id     UUID    DEFAULT NULL,
    IN p_source_batch_id  TEXT    DEFAULT NULL,
    IN p_watermark_column TEXT    DEFAULT NULL,
    IN p_force_full       BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
SET work_mem = '256MB'
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
      AND t.target_table  = 'loans';

    IF v_config_id IS NULL THEN
        RAISE EXCEPTION 'raw.loans is not registered in audit.source_tables - run 03_register_sources.sql.';
    END IF;

    -- Read stored watermark config, then apply defaults / caller override
    SELECT w.watermark_column, w.watermark_strategy, w.last_watermark_value
    INTO v_wm_column, v_wm_strategy, v_last_wm
    FROM audit.etl_watermarks w
    WHERE w.config_id = v_config_id;

    v_wm_column   := COALESCE(p_watermark_column, v_wm_column, '_loaded_at');
    v_wm_strategy := COALESCE(v_wm_strategy, 'timestamp');

    IF v_wm_strategy NOT IN ('timestamp', 'numeric') THEN
        RAISE EXCEPTION 'Unsupported watermark_strategy % for raw.loans (use timestamp or numeric).', v_wm_strategy;
    END IF;

    -- Watermark column must exist on the source
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'loans'
          AND column_name  = v_wm_column
    ) THEN
        RAISE EXCEPTION 'Watermark column raw.loans.% does not exist.', v_wm_column;
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
    IF to_regclass('pg_temp._loans_src') IS NOT NULL THEN
        DROP TABLE _loans_src;
    END IF;

    -- Cleaned slice. Format args: (1) watermark column, (2) filter.
    -- Note: a literal % in this SQL must be written %% inside format().
    EXECUTE format($q$
        CREATE TEMP TABLE _loans_src ON COMMIT DROP AS
        WITH keyed AS (
            -- Clean the key first so dedupe works on the value we will store
            SELECT
                CASE WHEN TRIM(c.loan_id::TEXT) ~ '^[0-9]{1,18}$'
                     THEN TRIM(c.loan_id::TEXT)::BIGINT END AS loan_key,
                c.customer_id,
                c.branch_id,
                c.loan_type,
                c.loan_amount,
                c.interest_rate,
                c.term_months,
                c.start_date,
                c.status,
                c.created_at,
                c.loaded_at,
                c._batch_id,
                c._loaded_at,
                c.ctid AS _row_tid,
                c.%I AS _wm_val
            FROM raw.loans c
            WHERE %s
        ),
        dedup AS (
            -- Keep the LATEST row per loan; row position breaks ties
            SELECT
                k.*,
                ROW_NUMBER() OVER (
                    PARTITION BY k.loan_key
                    ORDER BY k._batch_id  DESC NULLS LAST,
                             k._loaded_at DESC NULLS LAST,
                             k._row_tid   DESC
                ) AS rnk
            FROM keyed k
            WHERE k.loan_key IS NOT NULL
        )
        SELECT
            d.loan_key AS loan_id,

            -- IDs: digits only (max 9) so the INT cast cannot fail
            CASE WHEN TRIM(d.customer_id::TEXT) ~ '^[0-9]{1,9}$'
                 THEN TRIM(d.customer_id::TEXT)::INT END AS customer_id,

            CASE WHEN TRIM(d.branch_id::TEXT) ~ '^[0-9]{1,9}$'
                 THEN TRIM(d.branch_id::TEXT)::INT END AS branch_id,

            -- Trim, collapse spaces/underscores/hyphens, Title Case, allowed list only
            CASE
                WHEN INITCAP(NULLIF(regexp_replace(TRIM(d.loan_type::TEXT), '[\s_\-]+', ' ', 'g'), ''))
                     IN ('Home Loan', 'Gold Loan', 'Personal Loan',
                         'Education Loan', 'Auto Loan', 'Business Loan')
                THEN INITCAP(NULLIF(regexp_replace(TRIM(d.loan_type::TEXT), '[\s_\-]+', ' ', 'g'), ''))
                ELSE NULL
            END AS loan_type,

            -- Numeric, max 12 integer digits, > 0 (zero -> NULL; no negatives by regex)
            CASE
                WHEN TRIM(d.loan_amount::TEXT) ~ '^[0-9]{1,12}(\.[0-9]{1,2})?$'
                THEN NULLIF(TRIM(d.loan_amount::TEXT)::NUMERIC(14,2), 0)
                ELSE NULL
            END AS loan_amount,

            -- Rate parsed once (see lateral below), then range checked: 0 < rate <= 100
            CASE
                WHEN r.rate > 0 AND r.rate <= 100
                THEN r.rate
                ELSE NULL
            END AS interest_rate,

            -- Whole months, 1 to 600
            CASE
                WHEN TRIM(d.term_months::TEXT) ~ '^[0-9]{1,4}$'
                THEN CASE
                         WHEN TRIM(d.term_months::TEXT)::INT BETWEEN 1 AND 600
                         THEN TRIM(d.term_months::TEXT)::INT
                     END
                ELSE NULL
            END AS term_months,

            -- Valid date (time part ignored), not in the future, not before 2000
            CASE
                WHEN p.td BETWEEN DATE '2000-01-01' AND CURRENT_DATE
                THEN p.td
                ELSE NULL
            END AS start_date,

            -- Trim, collapse spaces/underscores/hyphens, Title Case, allowed list only
            CASE
                WHEN INITCAP(NULLIF(regexp_replace(TRIM(d.status::TEXT), '[\s_\-]+', ' ', 'g'), ''))
                     IN ('Active', 'Closed', 'Written Off', 'Defaulted')
                THEN INITCAP(NULLIF(regexp_replace(TRIM(d.status::TEXT), '[\s_\-]+', ' ', 'g'), ''))
                ELSE NULL
            END AS status,

            d.created_at,
            d.loaded_at,
            d._batch_id  AS source_batch_id,
            d._loaded_at AS source_loaded_at,
            d._wm_val    AS wm_val
        FROM dedup d
        -- OFFSET 0 = optimiser fence: parse each value ONCE per row
        -- (without it Postgres re-runs the parse at every use of p.td / r.rate)
        CROSS JOIN LATERAL (
            SELECT staging.try_date(LEFT(TRIM(d.start_date::TEXT), 10)) AS td
            OFFSET 0
        ) p
        CROSS JOIN LATERAL (
            SELECT CASE
                       WHEN TRIM(d.interest_rate::TEXT) ~ '^[0-9]{1,3}(\.[0-9]{1,4})?$'
                       THEN TRIM(d.interest_rate::TEXT)::NUMERIC(7,4)
                   END AS rate
            OFFSET 0
        ) r
        WHERE d.rnk = 1
    $q$, v_wm_column, v_wm_cond);

    -- Temp tables are not auto-analyzed; give the planner real stats
    ANALYZE _loans_src;

    SELECT count(*) INTO v_source_rows FROM _loans_src;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- Runs before the INSERT so new rows are never compared against themselves.
    -- History: one row per changed column, per loan (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'staging.loans',
        s.loan_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        s.source_batch_id,
        p_table_run_id
    FROM staging.loans t
    JOIN _loans_src s USING (loan_id)
    CROSS JOIN LATERAL (VALUES
        ('customer_id',   t.customer_id::TEXT,   s.customer_id::TEXT),
        ('branch_id',     t.branch_id::TEXT,     s.branch_id::TEXT),
        ('loan_type',     t.loan_type::TEXT,     s.loan_type::TEXT),
        ('loan_amount',   t.loan_amount::TEXT,   s.loan_amount::TEXT),
        ('interest_rate', t.interest_rate::TEXT, s.interest_rate::TEXT),
        ('term_months',   t.term_months::TEXT,   s.term_months::TEXT),
        ('start_date',    t.start_date::TEXT,    s.start_date::TEXT),
        ('status',        t.status::TEXT,        s.status::TEXT)
    ) AS ch(col, old_v, new_v)
    -- Cheap typed compare first: unchanged rows never reach the VALUES expansion
    WHERE ROW(t.customer_id, t.branch_id, t.loan_type, t.loan_amount,
              t.interest_rate, t.term_months, t.start_date, t.status)
          IS DISTINCT FROM
          ROW(s.customer_id, s.branch_id, s.loan_type, s.loan_amount,
              s.interest_rate, s.term_months, s.start_date, s.status)
      AND ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite only rows whose business columns changed
    UPDATE staging.loans t
    SET
        customer_id      = s.customer_id,
        branch_id        = s.branch_id,
        loan_type        = s.loan_type,
        loan_amount      = s.loan_amount,
        interest_rate    = s.interest_rate,
        term_months      = s.term_months,
        start_date       = s.start_date,
        status           = s.status,
        created_at       = s.created_at,
        loaded_at        = s.loaded_at,
        source_batch_id  = s.source_batch_id,
        source_loaded_at = s.source_loaded_at
    FROM _loans_src s
    WHERE t.loan_id = s.loan_id
      AND ROW(
            t.customer_id, t.branch_id, t.loan_type, t.loan_amount,
            t.interest_rate, t.term_months, t.start_date, t.status
      ) IS DISTINCT FROM ROW(
            s.customer_id, s.branch_id, s.loan_type, s.loan_amount,
            s.interest_rate, s.term_months, s.start_date, s.status
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- ========================= INSERT new loans =========================
    INSERT INTO staging.loans (
        loan_id,
        customer_id,
        branch_id,
        loan_type,
        loan_amount,
        interest_rate,
        term_months,
        start_date,
        status,
        created_at,
        loaded_at,
        source_batch_id,
        source_loaded_at
    )
    SELECT
        s.loan_id,
        s.customer_id,
        s.branch_id,
        s.loan_type,
        s.loan_amount,
        s.interest_rate,
        s.term_months,
        s.start_date,
        s.status,
        s.created_at,
        s.loaded_at,
        s.source_batch_id,
        s.source_loaded_at
    FROM _loans_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM staging.loans t
        WHERE t.loan_id = s.loan_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- Matched rows that were neither inserted nor updated
    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = typed max of the processed slice ----
    IF v_source_rows > 0 THEN
        SELECT max(wm_val)::TEXT INTO v_new_wm FROM _loans_src;
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
    RAISE NOTICE 'loans load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: % | %s',
        p_source_batch_id, v_source_rows, v_inserted, v_updated, v_unchanged,
        v_history_rows, COALESCE(v_watermark_advanced, 'unchanged'),
        ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at))::NUMERIC, 1);

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
        'raw.loans',
        'staging.loans',
        'staging',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'staging.sp_load_loans_scd1',
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
