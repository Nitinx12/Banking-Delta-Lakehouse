-- ============================================================
-- Script:   10_sp_load_support_tickets_scd1.sql
-- Purpose:  Incremental SCD Type 1 load: raw.support_tickets -> staging.support_tickets
-- Database: banking_delta (schemas: staging, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\staging\10_sp_load_support_tickets_scd1.sql
--
-- Notes:
--   * Watermark comes from audit.etl_watermarks; NULL = bootstrap (load all).
--   * Watermark advances only on success, to max value processed.
--   * Overwritten values go to the shared staging.scd1_history.
--
-- Cleaning rules (invalid value -> NULL, row is kept unless noted):
--   ticket_id           digits only (invalid -> row dropped)
--   customer_id         digits only, 1-9 long
--   issue_type          trimmed, spaces collapsed, Title Case, allowed list only
--   date_opened         valid date, not in the future, not before 2000-01-01
--   date_resolved       valid date, not in the future, not before 2000-01-01
--   status              trimmed, canonical case, allowed list only
--   satisfaction_score  integer 1-5
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('raw.support_tickets') IS NULL THEN
        RAISE EXCEPTION 'raw.support_tickets not found - land the source first.';
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
    table_name       VARCHAR(128) NOT NULL,
    record_key       TEXT         NOT NULL,
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
-- Target: current-state support tickets (one row per ticket)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS staging.support_tickets (
    ticket_id            BIGINT        NOT NULL,
    customer_id          INTEGER,
    issue_type           VARCHAR(100),
    date_opened          DATE,
    date_resolved        DATE,
    status               VARCHAR(20),
    satisfaction_score   INTEGER,
    created_at           TIMESTAMP,
    loaded_at            TIMESTAMP,
    source_batch_id      TEXT,
    source_loaded_at     TIMESTAMPTZ,
    row_added_at         TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at       TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_support_tickets PRIMARY KEY (ticket_id),
    CONSTRAINT chk_support_tickets_status
        CHECK (status IS NULL OR status IN ('Open', 'Resolved', 'Escalated')),
    CONSTRAINT chk_support_tickets_score
        CHECK (satisfaction_score IS NULL OR satisfaction_score BETWEEN 1 AND 5)
);

COMMENT ON TABLE staging.support_tickets IS
    'Cleaned support tickets, SCD Type 1 (current state, overwritten in place).';

CREATE INDEX IF NOT EXISTS idx_support_tickets_customer
    ON staging.support_tickets (customer_id);

DROP TRIGGER IF EXISTS trg_support_tickets_updated_at ON staging.support_tickets;
CREATE TRIGGER trg_support_tickets_updated_at
    BEFORE UPDATE ON staging.support_tickets
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Seed watermark row for raw.support_tickets (safe to re-run)
-- ------------------------------------------------------------
INSERT INTO audit.etl_watermarks (
    source_id, config_id, watermark_column, watermark_strategy
)
SELECT t.source_id, t.config_id, '_loaded_at', 'timestamp'
FROM audit.source_tables t
WHERE t.target_schema = 'raw'
  AND t.target_table  = 'support_tickets'
ON CONFLICT (config_id) DO NOTHING;

-- ------------------------------------------------------------
-- Load procedure (incremental SCD Type 1)
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_load_support_tickets_scd1(UUID, TEXT, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE staging.sp_load_support_tickets_scd1(
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
            'raw.support_tickets', 'staging.support_tickets',
            'staging', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    SELECT r.source_id, t.config_id
    INTO v_source_id, v_config_id
    FROM audit.source_tables t
    JOIN audit.source_registry r USING (source_id)
    WHERE t.target_schema = 'raw'
      AND t.target_table  = 'support_tickets';

    IF v_config_id IS NULL THEN
        RAISE EXCEPTION 'raw.support_tickets is not registered in audit.source_tables - run 03_register_sources.sql.';
    END IF;

    SELECT w.watermark_column, w.watermark_strategy, w.last_watermark_value
    INTO v_wm_column, v_wm_strategy, v_last_wm
    FROM audit.etl_watermarks w
    WHERE w.config_id = v_config_id;

    v_wm_column   := COALESCE(p_watermark_column, v_wm_column, '_loaded_at');
    v_wm_strategy := COALESCE(v_wm_strategy, 'timestamp');

    IF v_wm_strategy NOT IN ('timestamp', 'numeric') THEN
        RAISE EXCEPTION 'Unsupported watermark_strategy % for raw.support_tickets (use timestamp or numeric).', v_wm_strategy;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'raw'
          AND table_name   = 'support_tickets'
          AND column_name  = v_wm_column
    ) THEN
        RAISE EXCEPTION 'Watermark column raw.support_tickets.% does not exist.', v_wm_column;
    END IF;

    IF v_last_wm IS NULL OR p_force_full THEN
        v_wm_cond := 'TRUE';
    ELSIF v_wm_strategy = 'timestamp' THEN
        v_wm_cond := format('c.%I > %L::TIMESTAMPTZ', v_wm_column, v_last_wm);
    ELSE
        v_wm_cond := format('c.%I > %L::NUMERIC', v_wm_column, v_last_wm);
    END IF;

    IF to_regclass('pg_temp._support_tickets_src') IS NOT NULL THEN
        DROP TABLE _support_tickets_src;
    END IF;

    EXECUTE format($q$
        CREATE TEMP TABLE _support_tickets_src ON COMMIT DROP AS
        WITH duplicate_filter AS (
            SELECT
                c.*,
                c.%I AS _wm_val,
                ROW_NUMBER() OVER (
                    PARTITION BY c.ticket_id
                    ORDER BY c._batch_id DESC, c._loaded_at DESC, c._id DESC
                ) AS rnk
            FROM raw.support_tickets c
            WHERE %s
        ),
        cleaned_base AS (
            SELECT
                CASE WHEN TRIM(ticket_id::TEXT) ~ '^[0-9]+$'
                     THEN TRIM(ticket_id::TEXT)::BIGINT END AS ticket_id,

                CASE WHEN TRIM(customer_id::TEXT) ~ '^[0-9]{1,9}$'
                     THEN TRIM(customer_id::TEXT)::INT END AS customer_id,

                CASE
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'APP LOGIN ISSUE'      THEN 'App Login Issue'
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'ACCOUNT STATEMENT'    THEN 'Account Statement'
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'CARD BLOCKED'         THEN 'Card Blocked'
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'CHEQUE BOUNCE'        THEN 'Cheque Bounce'
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'FRAUD REPORT'         THEN 'Fraud Report'
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'INTEREST QUERY'       THEN 'Interest Query'
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'KYC UPDATE'           THEN 'KYC Update'
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'LOAN QUERY'           THEN 'Loan Query'
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'NET BANKING ISSUE'    THEN 'Net Banking Issue'
                    WHEN UPPER(TRIM(issue_type::TEXT)) = 'WRONG DEBIT'          THEN 'Wrong Debit'
                    ELSE NULL
                END AS issue_type,

                CASE
                    WHEN p.o BETWEEN DATE '2000-01-01' AND CURRENT_DATE
                    THEN p.o
                    ELSE NULL
                END AS date_opened,

                CASE
                    WHEN p.r BETWEEN DATE '2000-01-01' AND CURRENT_DATE
                    THEN p.r
                    ELSE NULL
                END AS date_resolved,

                CASE
                    WHEN UPPER(TRIM(status::TEXT)) = 'OPEN'      THEN 'Open'
                    WHEN UPPER(TRIM(status::TEXT)) = 'RESOLVED'  THEN 'Resolved'
                    WHEN UPPER(TRIM(status::TEXT)) = 'ESCALATED' THEN 'Escalated'
                    ELSE NULL
                END AS status,

                CASE
                    WHEN TRIM(satisfaction_score::TEXT) ~ '^[0-9]+$'
                     AND TRIM(satisfaction_score::TEXT)::INT BETWEEN 1 AND 5
                    THEN TRIM(satisfaction_score::TEXT)::INT
                    ELSE NULL
                END AS satisfaction_score,

                created_at,
                loaded_at,
                _batch_id,
                _loaded_at,
                f._wm_val AS wm_val
            FROM duplicate_filter f
            CROSS JOIN LATERAL (
                SELECT staging.try_date(LEFT(TRIM(f.date_opened::TEXT), 10)) AS o,
                       staging.try_date(LEFT(TRIM(f.date_resolved::TEXT), 10)) AS r
                OFFSET 0
            ) p
            WHERE rnk = 1
        )
        SELECT
            cb.ticket_id,
            cb.customer_id,
            cb.issue_type,
            cb.date_opened,
            cb.date_resolved,
            cb.status,
            cb.satisfaction_score,
            cb.created_at,
            cb.loaded_at,
            cb._batch_id  AS source_batch_id,
            cb._loaded_at AS source_loaded_at,
            cb.wm_val     AS wm_val
        FROM cleaned_base cb
        WHERE cb.ticket_id IS NOT NULL
    $q$, v_wm_column, v_wm_cond);

    SELECT count(*) INTO v_source_rows FROM _support_tickets_src;

    -- ===================== INSERT new tickets =====================
    INSERT INTO staging.support_tickets (
        ticket_id,
        customer_id,
        issue_type,
        date_opened,
        date_resolved,
        status,
        satisfaction_score,
        created_at,
        loaded_at,
        source_batch_id,
        source_loaded_at
    )
    SELECT
        s.ticket_id,
        s.customer_id,
        s.issue_type,
        s.date_opened,
        s.date_resolved,
        s.status,
        s.satisfaction_score,
        s.created_at,
        s.loaded_at,
        s.source_batch_id,
        s.source_loaded_at
    FROM _support_tickets_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM staging.support_tickets t
        WHERE t.ticket_id = s.ticket_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- ============ UPDATE existing: history first, then overwrite ============
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'staging.support_tickets',
        s.ticket_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        s.source_batch_id,
        p_table_run_id
    FROM staging.support_tickets t
    JOIN _support_tickets_src s USING (ticket_id)
    CROSS JOIN LATERAL (VALUES
        ('customer_id',        t.customer_id::TEXT,        s.customer_id::TEXT),
        ('issue_type',         t.issue_type::TEXT,         s.issue_type::TEXT),
        ('date_opened',        t.date_opened::TEXT,        s.date_opened::TEXT),
        ('date_resolved',      t.date_resolved::TEXT,      s.date_resolved::TEXT),
        ('status',             t.status::TEXT,             s.status::TEXT),
        ('satisfaction_score', t.satisfaction_score::TEXT, s.satisfaction_score::TEXT)
    ) AS ch(col, old_v, new_v)
    WHERE ROW(t.customer_id, t.issue_type, t.date_opened, t.date_resolved, t.status, t.satisfaction_score)
          IS DISTINCT FROM
          ROW(s.customer_id, s.issue_type, s.date_opened, s.date_resolved, s.status, s.satisfaction_score)
      AND ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    UPDATE staging.support_tickets t
    SET
        customer_id        = s.customer_id,
        issue_type         = s.issue_type,
        date_opened        = s.date_opened,
        date_resolved      = s.date_resolved,
        status             = s.status,
        satisfaction_score = s.satisfaction_score,
        created_at         = s.created_at,
        loaded_at          = s.loaded_at,
        source_batch_id    = s.source_batch_id,
        source_loaded_at   = s.source_loaded_at
    FROM _support_tickets_src s
    WHERE t.ticket_id = s.ticket_id
      AND ROW(
            t.customer_id, t.issue_type, t.date_opened, t.date_resolved, t.status, t.satisfaction_score
      ) IS DISTINCT FROM ROW(
            s.customer_id, s.issue_type, s.date_opened, s.date_resolved, s.status, s.satisfaction_score
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    v_unchanged := v_source_rows - v_inserted - v_updated;

    IF v_source_rows > 0 THEN
        SELECT max(wm_val)::TEXT INTO v_new_wm FROM _support_tickets_src;
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

        v_watermark_advanced := COALESCE(v_last_wm, '<bootstrap>') || ' -> ' || v_new_wm;
    END IF;

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

    RAISE NOTICE 'support_tickets load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
        p_source_batch_id, v_source_rows, v_inserted, v_updated, v_unchanged,
        v_history_rows, COALESCE(v_watermark_advanced, 'unchanged');

EXCEPTION WHEN OTHERS THEN
    INSERT INTO audit.pipeline_errors (
        pipeline_run_id, table_run_id, source_table, target_table,
        processing_layer, error_category, severity, error_message,
        error_details, is_recoverable, resolution_status
    )
    VALUES (
        COALESCE((SELECT pipeline_run_id FROM audit.table_runs WHERE table_run_id = p_table_run_id), v_pipeline_run_id),
        p_table_run_id,
        'raw.support_tickets',
        'staging.support_tickets',
        'staging',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'staging.sp_load_support_tickets_scd1',
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

