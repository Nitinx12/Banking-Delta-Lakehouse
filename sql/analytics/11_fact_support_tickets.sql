-- ============================================================
-- Script:   11_fact_support_tickets.sql
-- Purpose:  Incremental load: staging.support_tickets -> analytics.fact_support_tickets
-- Database: banking_delta (schemas: staging, analytics, audit)
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\11_fact_support_tickets.sql
-- Depends on: 01_dim_customer.sql (customer_key lookup)
--
-- Grain:   one row per support ticket (ticket_id).
--          Tickets change over time (Open -> Escalated -> Resolved), so this is an
--          "accumulating snapshot": the row is updated as the ticket progresses.
-- Measures: resolution_days (date_resolved - date_opened), satisfaction_score,
--           is_resolved (flag).
-- Keys:    ticket_id (degenerate dimension / PK), customer_key -> dim_customer,
--          opened_date_key / resolved_date_key (YYYYMMDD int; -1 = no date).
--
-- Notes:
--   * issue_type and status stay as text columns (short fixed lists, so no
--     separate dimension is needed).
--   * resolution_days is NULL unless both dates exist and the resolved date is
--     not before the opened date.
--   * Date keys have no foreign key yet: add them when dim_date exists.
--   * Late-arriving customers: tickets pointing at customer_key = -1 are
--     re-processed automatically once the customer exists in dim_customer.
--   * Watermark = staging.support_tickets.row_updated_at, stored on the fact row
--     (source_row_updated_at, indexed so max() is instant).
--   * Overwritten values go to the shared table staging.scd1_history
--     (table_name = 'analytics.fact_support_tickets').
--   * Audit: closes audit.table_runs, logs failures to audit.pipeline_errors.
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    IF to_regclass('staging.support_tickets') IS NULL THEN
        RAISE EXCEPTION 'staging.support_tickets not found - run 10_sp_load_support_tickets_scd1.sql first.';
    END IF;

    IF to_regclass('staging.scd1_history') IS NULL THEN
        RAISE EXCEPTION 'staging.scd1_history not found - run 01_sp_load_customers_scd1.sql first.';
    END IF;

    IF to_regclass('analytics.dim_customer') IS NULL THEN
        RAISE EXCEPTION 'analytics.dim_customer not found - run 01_dim_customer.sql first.';
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
-- Fact table
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS analytics.fact_support_tickets (
    ticket_id             BIGINT        NOT NULL,                       -- degenerate dimension / PK
    customer_key          INTEGER       NOT NULL DEFAULT -1,            -- -> dim_customer
    customer_id           INTEGER,                                      -- natural key of customer
    issue_type            VARCHAR(100)  NOT NULL DEFAULT 'Unknown',
    status                VARCHAR(20)   NOT NULL DEFAULT 'Unknown',
    is_resolved           BOOLEAN       NOT NULL DEFAULT FALSE,         -- status = 'Resolved'
    opened_date_key       INTEGER       NOT NULL DEFAULT -1,            -- YYYYMMDD, -1 = unknown
    resolved_date_key     INTEGER       NOT NULL DEFAULT -1,            -- YYYYMMDD, -1 = not resolved / unknown
    date_opened           DATE,
    date_resolved         DATE,
    resolution_days       INTEGER,                                      -- measure
    satisfaction_score    INTEGER,                                      -- measure (1-5)
    source_batch_id       TEXT,                                         -- lineage
    source_row_updated_at TIMESTAMPTZ,                                  -- lineage + watermark
    row_added_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    row_updated_at        TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_fact_support_tickets PRIMARY KEY (ticket_id),
    CONSTRAINT fk_fact_st_customer
        FOREIGN KEY (customer_key) REFERENCES analytics.dim_customer (customer_key),
    CONSTRAINT chk_fact_st_score
        CHECK (satisfaction_score IS NULL OR satisfaction_score BETWEEN 1 AND 5),
    CONSTRAINT chk_fact_st_resolution_days
        CHECK (resolution_days IS NULL OR resolution_days >= 0)
);

COMMENT ON TABLE analytics.fact_support_tickets IS
    'Support ticket fact (accumulating snapshot). Grain: one row per ticket_id, updated as the ticket progresses.';

CREATE INDEX IF NOT EXISTS idx_fact_st_customer_key
    ON analytics.fact_support_tickets (customer_key);

CREATE INDEX IF NOT EXISTS idx_fact_st_opened_date_key
    ON analytics.fact_support_tickets (opened_date_key);

CREATE INDEX IF NOT EXISTS idx_fact_st_issue_status
    ON analytics.fact_support_tickets (issue_type, status);

-- Watermark lookup: max(source_row_updated_at)
CREATE INDEX IF NOT EXISTS idx_fact_st_source_updated
    ON analytics.fact_support_tickets (source_row_updated_at);

DROP TRIGGER IF EXISTS trg_fact_st_updated_at ON analytics.fact_support_tickets;
CREATE TRIGGER trg_fact_st_updated_at
    BEFORE UPDATE ON analytics.fact_support_tickets
    FOR EACH ROW EXECUTE FUNCTION audit.set_updated_at('row_updated_at');

-- ------------------------------------------------------------
-- Load procedure (incremental)
-- Usage: CALL analytics.sp_load_fact_support_tickets();
-- All params optional. p_force_full = TRUE ignores the watermark.
-- No COMMIT/ROLLBACK inside: caller owns the transaction.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.sp_load_fact_support_tickets(UUID, TEXT, BOOLEAN);

CREATE OR REPLACE PROCEDURE analytics.sp_load_fact_support_tickets(
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
            'staging.support_tickets',
            'analytics.fact_support_tickets',
            'analytics', 'MERGE', 'RUNNING'
        )
        ON CONFLICT (table_run_id) DO NOTHING;
    END IF;

    -- Current watermark = newest staging change already in the fact (index lookup)
    SELECT max(f.source_row_updated_at)
    INTO v_last_wm
    FROM analytics.fact_support_tickets f;

    -- Allow more than one call per transaction
    IF to_regclass('pg_temp._fact_st_src') IS NOT NULL THEN
        DROP TABLE _fact_st_src;
    END IF;

    -- Slice of staging to process, with surrogate-key lookup and derived measures
    CREATE TEMP TABLE _fact_st_src ON COMMIT DROP AS
    SELECT
        t.ticket_id,
        COALESCE(cu.customer_key, -1)                              AS customer_key,
        t.customer_id,
        COALESCE(t.issue_type, 'Unknown')                          AS issue_type,
        COALESCE(t.status, 'Unknown')                              AS status,
        COALESCE(t.status = 'Resolved', FALSE)                     AS is_resolved,
        COALESCE(TO_CHAR(t.date_opened, 'YYYYMMDD')::INT, -1)      AS opened_date_key,
        COALESCE(TO_CHAR(t.date_resolved, 'YYYYMMDD')::INT, -1)    AS resolved_date_key,
        t.date_opened,
        t.date_resolved,
        CASE
            WHEN t.date_opened IS NOT NULL
             AND t.date_resolved IS NOT NULL
             AND t.date_resolved >= t.date_opened
            THEN (t.date_resolved - t.date_opened)
        END                                                        AS resolution_days,
        t.satisfaction_score,
        t.row_updated_at                                           AS source_row_updated_at
    FROM staging.support_tickets t
    LEFT JOIN analytics.dim_customer cu
           ON cu.customer_id = t.customer_id
    LEFT JOIN analytics.fact_support_tickets cur
           ON cur.ticket_id = t.ticket_id
    WHERE p_force_full
       OR v_last_wm IS NULL
       OR t.row_updated_at > v_last_wm
       -- Late-arriving customer: ticket was loaded with Unknown customer, customer exists now
       OR (cur.customer_key = -1 AND cu.customer_key IS NOT NULL);

    SELECT count(*) INTO v_source_rows FROM _fact_st_src;

    -- ============ UPDATE existing: history first, then overwrite ============
    -- Runs before the INSERT so new rows are never compared against themselves.
    -- History: one row per changed column, per ticket (must run before UPDATE)
    INSERT INTO staging.scd1_history (
        table_name, record_key, changed_column, old_value, new_value,
        source_batch_id, table_run_id
    )
    SELECT
        'analytics.fact_support_tickets',
        s.ticket_id::TEXT,
        ch.col,
        ch.old_v,
        ch.new_v,
        p_source_batch_id,
        p_table_run_id
    FROM analytics.fact_support_tickets f
    JOIN _fact_st_src s USING (ticket_id)
    CROSS JOIN LATERAL (VALUES
        ('customer_key',       f.customer_key::TEXT,       s.customer_key::TEXT),
        ('customer_id',        f.customer_id::TEXT,        s.customer_id::TEXT),
        ('issue_type',         f.issue_type::TEXT,         s.issue_type::TEXT),
        ('status',             f.status::TEXT,             s.status::TEXT),
        ('is_resolved',       f.is_resolved::TEXT,       s.is_resolved::TEXT),
        ('opened_date_key',   f.opened_date_key::TEXT,   s.opened_date_key::TEXT),
        ('resolved_date_key', f.resolved_date_key::TEXT, s.resolved_date_key::TEXT),
        ('date_opened',        f.date_opened::TEXT,        s.date_opened::TEXT),
        ('date_resolved',      f.date_resolved::TEXT,      s.date_resolved::TEXT),
        ('resolution_days',    f.resolution_days::TEXT,    s.resolution_days::TEXT),
        ('satisfaction_score', f.satisfaction_score::TEXT, s.satisfaction_score::TEXT)
    ) AS ch(col, old_v, new_v)
    -- Cheap typed compare first: unchanged rows never reach the VALUES expansion
    WHERE ROW(f.customer_key, f.customer_id, f.issue_type, f.status, f.date_opened,
              f.date_resolved, f.resolution_days, f.satisfaction_score)
          IS DISTINCT FROM
          ROW(s.customer_key, s.customer_id, s.issue_type, s.status, s.date_opened,
              s.date_resolved, s.resolution_days, s.satisfaction_score)
      AND ch.old_v IS DISTINCT FROM ch.new_v;

    GET DIAGNOSTICS v_history_rows = ROW_COUNT;

    -- Overwrite rows whose attributes changed. Rows where only the lineage
    -- (source_row_updated_at) moved are also touched, so the watermark advances
    -- instead of re-reading the same staging rows on every run.
    UPDATE analytics.fact_support_tickets f
    SET
        customer_key          = s.customer_key,
        customer_id           = s.customer_id,
        issue_type            = s.issue_type,
        status                = s.status,
        is_resolved           = s.is_resolved,
        opened_date_key       = s.opened_date_key,
        resolved_date_key     = s.resolved_date_key,
        date_opened           = s.date_opened,
        date_resolved         = s.date_resolved,
        resolution_days       = s.resolution_days,
        satisfaction_score    = s.satisfaction_score,
        source_batch_id       = p_source_batch_id,
        source_row_updated_at = s.source_row_updated_at
    FROM _fact_st_src s
    WHERE f.ticket_id = s.ticket_id
      AND ROW(
            f.customer_key, f.customer_id, f.issue_type, f.status, f.is_resolved,
            f.opened_date_key, f.resolved_date_key, f.date_opened, f.date_resolved,
            f.resolution_days, f.satisfaction_score, f.source_row_updated_at
      ) IS DISTINCT FROM ROW(
            s.customer_key, s.customer_id, s.issue_type, s.status, s.is_resolved,
            s.opened_date_key, s.resolved_date_key, s.date_opened, s.date_resolved,
            s.resolution_days, s.satisfaction_score, s.source_row_updated_at
      );

    GET DIAGNOSTICS v_updated = ROW_COUNT;

    -- ===================== INSERT new tickets =====================
    INSERT INTO analytics.fact_support_tickets (
        ticket_id, customer_key, customer_id, issue_type, status, is_resolved,
        opened_date_key, resolved_date_key, date_opened, date_resolved,
        resolution_days, satisfaction_score, source_batch_id, source_row_updated_at
    )
    SELECT
        s.ticket_id, s.customer_key, s.customer_id, s.issue_type, s.status, s.is_resolved,
        s.opened_date_key, s.resolved_date_key, s.date_opened, s.date_resolved,
        s.resolution_days, s.satisfaction_score, p_source_batch_id, s.source_row_updated_at
    FROM _fact_st_src s
    WHERE NOT EXISTS (
        SELECT 1 FROM analytics.fact_support_tickets f
        WHERE f.ticket_id = s.ticket_id
    );

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- Matched rows that were neither inserted nor updated
    v_unchanged := v_source_rows - v_inserted - v_updated;

    -- ---- New watermark = max staging change processed ----
    SELECT max(source_row_updated_at) INTO v_new_wm FROM _fact_st_src;
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
            'watermark_column',   'staging.support_tickets.row_updated_at',
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
    RAISE NOTICE 'fact_support_tickets load OK | batch=% | source=% inserted=% updated=% unchanged=% history=% | watermark: %',
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
        'staging.support_tickets',
        'analytics.fact_support_tickets',
        'analytics',
        SQLSTATE,
        'ERROR',
        SQLERRM,
        jsonb_build_object(
            'procedure',        'analytics.sp_load_fact_support_tickets',
            'source_batch_id',  p_source_batch_id,
            'watermark_column', 'staging.support_tickets.row_updated_at'
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
CALL analytics.sp_load_fact_support_tickets();
