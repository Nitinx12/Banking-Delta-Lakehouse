-- ============================================================
-- Script:   08_sp_load_loan_payments_scd1.sql
-- Purpose:  Incremental SCD Type 1 load: raw.loan_payments -> staging.loan_payments
-- Database: banking_delta (schemas: staging, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\staging\08_sp_load_loan_payments_scd1.sql
--
-- Notes:
--   * Watermark comes from audit.etl_watermarks; NULL = bootstrap (load all).
--   * Watermark advances only on success, to max value processed.
--   * Overwritten values go to the shared staging.scd1_history.
--   * Source column late_payment_flag is stored as is_late.
--
-- Cleaning rules (invalid value -> NULL, row is kept):
--   payment_id           digits only, 1-18 long (invalid -> row dropped)
--   loan_id              digits only, 1-18 long
--   payment_date         valid date (time part ignored), not in the future,
--                        not before 2000-01-01
--   amount_paid          numeric, up to 2 decimals, greater than 0
--   principal_component  numeric, up to 2 decimals, zero or more
--   interest_component   numeric, up to 2 decimals, zero or more
--   is_late              1/true/t/yes/y -> TRUE ; 0/false/f/no/n -> FALSE
--
-- Amount maths (amount_paid = principal_component + interest_component):
--   * One of the three missing or invalid, other two valid:
--       derive it (amount = principal + interest, principal = amount - interest,
--       interest = amount - principal). Derived values must stay valid
--       (amount > 0, components >= 0), otherwise they stay NULL.
--   * All three present: kept exactly as received, even when they disagree.
--   * amount_check records the outcome of the maths:
--       OK          all three present and |amount - (principal + interest)| <= 0.01
--       DERIVED     one value was rebuilt from the other two
--       MISMATCH    all three present but the difference is more than 0.01
--       INCOMPLETE  two or more values missing, nothing can be rebuilt
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('raw.loan_payments') IS NULL THEN
        RAISE EXCEPTION 'raw.loan_payments not found - land the source first.';
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
    table_name       VARCHAR(128) NOT NULL,   -- e.g. 'staging.loan_payments'
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
-- Target: current-state loan payments (one row per payment)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.loan_payments (
    payment_id           BIGINT        NOT NULL,
    loan_id              BIGINT,
    payment_date         DATE,
    amount_paid          NUMERIC(14,2),
    principal_component  NUMERIC(14,2),
    interest_component   NUMERIC(14,2),
    is_late              BOOLEAN,
    amount_check         VARCHAR(12)   NOT NULL,
    created_at           TIMESTAMP,
    loaded_at            TIMESTAMP,
    source_batch_id      TEXT,
    source_loaded_at     TIMESTAMPTZ,
    row_added_at         TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at       TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_loan_payments PRIMARY KEY (payment_id),
    CONSTRAINT chk_loan_payments_amount
        CHECK (amount_paid IS NULL OR amount_paid > 0),
    CONSTRAINT chk_loan_payments_principal
        CHECK (principal_component IS NULL OR principal_component >= 0),
    CONSTRAINT chk_loan_payments_interest
        CHECK (interest_component IS NULL OR interest_component >= 0),
    CONSTRAINT chk_loan_payments_amount_check
        CHECK (amount_check IN ('OK', 'DERIVED', 'MISMATCH', 'INCOMPLETE')),
    CONSTRAINT chk_loan_payments_sum
        CHECK (amount_check NOT IN ('OK', 'DERIVED')
               OR ABS(amount_paid - (principal_component + interest_component)) <= 0.01)
);

COMMENT ON TABLE staging.loan_payments IS
    'Cleaned loan payments, SCD Type 1 (current state, overwritten in place).';

COMMENT ON COLUMN staging.loan_payments.amount_check IS
    'OK = amount equals principal + interest (tolerance 0.01); DERIVED = one value rebuilt from the other two; MISMATCH = all present but do not add up; INCOMPLETE = cannot be rebuilt.';

CREATE INDEX IF NOT EXISTS idx_loan_payments_loan
    ON staging.loan_payments (loan_id);

CREATE INDEX IF NOT EXISTS idx_loan_payments_date
    ON staging.loan_payments (payment_date);

DROP TRIGGER IF EXISTS trg_loan_payments_updated_at ON staging.loan_payments;
CREATE TRIGGER trg_loan_payments_updated_at
    BEFORE UPDATE ON staging.loan_payments
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at();

-- ------------------------------------------------------------
-- Seed watermark row for raw.loan_payments (safe to re-run)
-- ------------------------------------------------------------
INSERT INTO audit.etl_watermarks (
    source_id, config_id, watermark_column, watermark_strategy
)
SELECT t.source_id, t.config_id, '_loaded_at', 'timestamp'
FROM audit.source_tables t
WHERE t.target_schema = 'raw'
  AND t.target_table  = 'loan_payments'
ON CONFLICT (config_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- Usage: CALL staging.sp_load_loan_payments_scd1();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- work_mem applies only while this procedure runs.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE staging.sp_load_loan_payments_scd1(
    IN p_table_run_id     UUID    DEFAULT NULL,
    IN p_source_batch_id  TEXT    DEFAULT NULL,
    IN p_watermark_column TEXT    DEFAULT NULL,
    IN p_force_full       BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql
SET work_mem = '256MB'
AS $$
DECLARE
    -- Allowed gap between amount_paid and principal + interest
    c_tolerance          CONSTANT NUMERIC := 0.01;
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
    v_mismatch           BIGINT := 0;
    v_derived            BIGINT := 0;
    v_incomplete         BIGINT := 0;
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
      AND t.target_table  = 'loan_payments';

    IF v_config_id IS NULL THEN
        RAISE EXCEPTION 'raw.loan_payments is not registered in audit.source_tables - run 03_register_sources.sql.';
    END IF;

    -- Read stored watermark config, then apply defaults / caller override
    SELECT w.watermark_column, w.watermark_strategy, w.last_watermark_value
    INTO v_wm_column, v_wm_strategy, v_last_wm
    FROM audit.etl_watermarks w
    WHERE w.config_id = v_config_id;

    v_wm_column   := COALESCE(p_watermark_column, v_wm_column, '_loaded_at');
    v_wm_strategy := COALESCE(v_wm_strategy, 'timestamp');

    IF v_wm_strategy NOT IN ('timestamp', 'numeric') THEN
        RAISE EXCEPTION 'Unsupported watermark_strategy % for raw.loan_payments (use timestamp or numeric).', v_wm_strategy;
    END IF;

    -- Watermark column must exist on the source
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'loan_payments'
          AND column_name  = v_wm_column
    ) THEN
        RAISE EXCEPTION 'Watermark column raw.loan_payments.% does not exist.', v_wm_column;
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
    IF to_regclass('pg_temp._loan_payments_src') IS NOT NULL THEN
        DROP TABLE _loan_payments_src;
    END IF;

    -- Cleaned slice. Format args: (1) watermark column, (2) filter, (3) tolerance.
    -- Note: a literal % in this SQL must be written %% inside format().
    EXECUTE format($q$
        CREATE TEMP TABLE _loan_payments_src ON COMMIT DROP AS
        WITH keyed AS (
            -- Clean the key first so dedupe works on the value we will store
            SELECT
                CASE WHEN TRIM(c.payment_id::TEXT) ~ '^[0-9]{1,18}$'
                     THEN TRIM(c.payment_id::TEXT)::BIGINT END AS pay_key,
                c.loan_id,
                c.payment_date,
                c.amount_paid,
                c.principal_component,
                c.interest_component,
                c.late_payment_flag,
                c.created_at,
                c.loaded_at,
                c._batch_id,
                c._loaded_at,
                c.ctid AS _row_tid,
                c.%1$I AS _wm_val
            FROM raw.loan_payments c
            WHERE %2$s
        ),
        dedup AS (
            -- Keep the LATEST row per payment; row position breaks ties
            SELECT
                k.*,
                ROW_NUMBER() OVER (
                    PARTITION BY k.pay_key
                    ORDER BY k._batch_id  DESC NULLS LAST,
                             k._loaded_at DESC NULLS LAST,
                             k._row_tid   DESC
                ) AS rnk
            FROM keyed k
            WHERE k.pay_key IS NOT NULL
        ),
        parsed AS (
            -- Step 1: clean every column on its own, values parsed ONCE per row
            SELECT
                d.pay_key,

                CASE WHEN TRIM(d.loan_id::TEXT) ~ '^[0-9]{1,18}$'
                     THEN TRIM(d.loan_id::TEXT)::BIGINT END AS loan_id,

                -- Valid date (time part ignored), not in the future, not before 2000
                CASE
                    WHEN dt.td BETWEEN DATE '2000-01-01' AND CURRENT_DATE
                    THEN dt.td
                    ELSE NULL
                END AS payment_date,

                n.amt_raw,
                n.prin_raw,
                n.int_raw,

                -- Text/number flags -> boolean; anything else -> NULL
                CASE
                    WHEN LOWER(TRIM(d.late_payment_flag::TEXT)) IN ('1', 'true',  't', 'yes', 'y') THEN TRUE
                    WHEN LOWER(TRIM(d.late_payment_flag::TEXT)) IN ('0', 'false', 'f', 'no',  'n') THEN FALSE
                    ELSE NULL
                END AS is_late,

                d.created_at,
                d.loaded_at,
                d._batch_id,
                d._loaded_at,
                d._wm_val
            FROM dedup d
            -- OFFSET 0 = optimiser fence: parse each value ONCE per row
            CROSS JOIN LATERAL (
                SELECT staging.try_date(LEFT(TRIM(d.payment_date::TEXT), 10)) AS td
                OFFSET 0
            ) dt
            CROSS JOIN LATERAL (
                SELECT
                    -- Amount: max 12 integer digits, > 0 (zero -> NULL)
                    CASE
                        WHEN TRIM(d.amount_paid::TEXT) ~ '^[0-9]{1,12}(\.[0-9]{1,2})?$'
                        THEN NULLIF(TRIM(d.amount_paid::TEXT)::NUMERIC(14,2), 0)
                    END AS amt_raw,
                    -- Components: max 12 integer digits, zero allowed
                    CASE
                        WHEN TRIM(d.principal_component::TEXT) ~ '^[0-9]{1,12}(\.[0-9]{1,2})?$'
                        THEN TRIM(d.principal_component::TEXT)::NUMERIC(14,2)
                    END AS prin_raw,
                    CASE
                        WHEN TRIM(d.interest_component::TEXT) ~ '^[0-9]{1,12}(\.[0-9]{1,2})?$'
                        THEN TRIM(d.interest_component::TEXT)::NUMERIC(14,2)
                    END AS int_raw
                OFFSET 0
            ) n
            WHERE d.rnk = 1
        ),
        calc AS (
            -- Step 2: rebuild ONE missing value from the other two (never overwrite a valid one)
            SELECT
                pr.*,
                COALESCE(pr.amt_raw,
                         CASE WHEN pr.prin_raw IS NOT NULL AND pr.int_raw IS NOT NULL
                                   AND pr.prin_raw + pr.int_raw > 0
                              THEN pr.prin_raw + pr.int_raw END) AS amt_final,
                COALESCE(pr.prin_raw,
                         CASE WHEN pr.amt_raw IS NOT NULL AND pr.int_raw IS NOT NULL
                                   AND pr.amt_raw - pr.int_raw >= 0
                              THEN pr.amt_raw - pr.int_raw END) AS prin_final,
                COALESCE(pr.int_raw,
                         CASE WHEN pr.amt_raw IS NOT NULL AND pr.prin_raw IS NOT NULL
                                   AND pr.amt_raw - pr.prin_raw >= 0
                              THEN pr.amt_raw - pr.prin_raw END) AS int_final
            FROM parsed pr
        )
        SELECT
            c.pay_key        AS payment_id,
            c.loan_id,
            c.payment_date,
            c.amt_final      AS amount_paid,
            c.prin_final     AS principal_component,
            c.int_final      AS interest_component,
            c.is_late,

            -- Step 3: outcome of the maths
            CASE
                WHEN c.amt_final IS NULL OR c.prin_final IS NULL OR c.int_final IS NULL
                    THEN 'INCOMPLETE'
                WHEN c.amt_raw IS NULL OR c.prin_raw IS NULL OR c.int_raw IS NULL
                    THEN 'DERIVED'
                WHEN ABS(c.amt_raw - (c.prin_raw + c.int_raw)) <= %3$s
                    THEN 'OK'
                ELSE 'MISMATCH'
            END AS amount_check,

            c.created_at,
            c.loaded_at,
            c._batch_id  AS source_batch_id,
            c._loaded_at AS source_loaded_at,
            c._wm_val    AS wm_val
        FROM calc c
    $q$, v_wm_column, v_wm_cond, c_tolerance::TEXT);

    -- Temp tables are not auto-analyzed; give the planner real stats
    ANALYZE _loan_payments_src;

    SELECT
        count(*),
        count(*) FILTER (WHERE amount_check = 'MISMATCH'),
        count(*) FILTER (WHERE amount_check = 'DERIVED'),
        count(*) FILTER (WHERE amount_check = 'INCOMPLETE')
    INTO v_source_rows, v_mismatch, v_derived, v_incomplete
    FROM _loan_payments_src;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- Runs before the INSERT so new rows are never compared against themselves.
    -- History: one row per changed column, per payment (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'staging.loan_payments',
        s.payment_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        s.source_batch_id,
        p_table_run_id
    FROM staging.loan_payments t
    JOIN _loan_payments_src s USING (payment_id)
    CROSS JOIN LATERAL (VALUES
        ('loan_id',             t.loan_id::TEXT,             s.loan_id::TEXT),
        ('payment_date',        t.payment_date::TEXT,        s.payment_date::TEXT),
        ('amount_paid',         t.amount_paid::TEXT,         s.amount_paid::TEXT),
        ('principal_component', t.principal_component::TEXT, s.principal_component::TEXT),
        ('interest_component',  t.interest_component::TEXT,  s.interest_component::TEXT),
        ('is_late',             t.is_late::TEXT,             s.is_late::TEXT),
        ('amount_check',        t.amount_check::TEXT,        s.amount_check::TEXT)
    ) AS ch(col, old_v, new_v)
    -- Cheap typed compare first: unchanged rows never reach the VALUES expansion
    WHERE ROW(t.loan_id, t.payment_date, t.amount_paid, t.principal_component,
              t.interest_component, t.is_late, t.amount_check)
          IS DISTINCT FROM
          ROW(s.loan_id, s.payment_date, s.amount_paid, s.principal_component,
              s.interest_component, s.is_late, s.amount_check)
      AND ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite only rows whose business columns changed
    UPDATE staging.loan_payments t
    SET
        loan_id             = s.loan_id,
        payment_date        = s.payment_date,
        amount_paid         = s.amount_paid,
        principal_component = s.principal_component,
        interest_component  = s.interest_component,
        is_late             = s.is_late,
        amount_check        = s.amount_check,
        created_at          = s.created_at,
        loaded_at           = s.loaded_at,
        source_batch_id     = s.source_batch_id,
        source_loaded_at    = s.source_loaded_at
    FROM _loan_payments_src s
    WHERE t.payment_id = s.payment_id
      AND ROW(
            t.loan_id, t.payment_date, t.amount_paid, t.principal_component,
            t.interest_component, t.is_late, t.amount_check
      ) IS DISTINCT FROM ROW(
            s.loan_id, s.payment_date, s.amount_paid, s.principal_component,
            s.interest_component, s.is_late, s.amount_check
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- ====================== INSERT new payments ======================
    INSERT INTO staging.loan_payments (
        payment_id,
        loan_id,
        payment_date,
        amount_paid,
        principal_component,
        interest_component,
        is_late,
        amount_check,
        created_at,
        loaded_at,
        source_batch_id,
        source_loaded_at
    )
    SELECT
        s.payment_id,
        s.loan_id,
        s.payment_date,
        s.amount_paid,
        s.principal_component,
        s.interest_component,
        s.is_late,
        s.amount_check,
        s.created_at,
        s.loaded_at,
        s.source_batch_id,
        s.source_loaded_at
    FROM _loan_payments_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM staging.loan_payments t
        WHERE t.payment_id = s.payment_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- Matched rows that were neither inserted nor updated
    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = typed max of the processed slice ----
    IF v_source_rows > 0 THEN
        SELECT max(wm_val)::TEXT INTO v_new_wm FROM _loan_payments_src;
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
            'amount_mismatch',    v_mismatch,
            'amount_derived',     v_derived,
            'amount_incomplete',  v_incomplete,
            'amount_tolerance',   c_tolerance,
            'source_batch_id',    p_source_batch_id,
            'watermark_column',   v_wm_column,
            'watermark_strategy', v_wm_strategy,
            'force_full',         p_force_full
        )
    WHERE table_run_id = p_table_run_id;

    -- Summary (visible in psql / client messages)
    RAISE NOTICE 'loan_payments load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | mismatch=% derived=% incomplete=% | watermark: % | %s',
        p_source_batch_id, v_source_rows, v_inserted, v_updated, v_unchanged,
        v_history_rows, v_mismatch, v_derived, v_incomplete,
        COALESCE(v_watermark_advanced, 'unchanged'),
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
        'raw.loan_payments',
        'staging.loan_payments',
        'staging',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'staging.sp_load_loan_payments_scd1',
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
