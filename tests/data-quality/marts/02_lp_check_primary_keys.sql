-- ============================================================
-- Script Name : 02_lp_check_primary_keys.sql
-- Purpose     : Validate the grain of every table in the marts
--               schema. Fails with a single error that lists all
--               violations.
-- Key lookup  : marts are full-refresh CTAS aggregates and carry no
--               declared primary key, so the grain is declared per
--               table in v_grains and enforced here instead
-- Checks      : 1. Every mart has a grain configuration
--               2. Grain columns exist
--               3. No NULL values in the required grain columns
--                  (v_required; nullable grain columns such as
--                  region / state are excluded on purpose)
--               4. No duplicate grain values
--               5. No grain is configured for a missing table
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_primary_key_check(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'marts';

    -- grain (the combination that must be unique) per mart
    v_grains CONSTANT JSONB := '{
        "mart_customer_360":          ["customer_key"],
        "mart_branch_performance":    ["branch_key"],
        "mart_monthly_transactions":  ["month_start", "txn_type", "channel", "merchant_category", "txn_direction", "region", "state"],
        "mart_loan_portfolio":        ["loan_type", "status", "loan_amount_band", "term_band", "start_year"],
        "mart_card_fraud":            ["month_start", "card_type", "card_category", "card_tier", "merchant_category"],
        "mart_support_performance":   ["month_opened", "issue_type", "status", "customer_state", "income_band"],
        "mart_kpi_monthly":           ["month_start"]
    }'::JSONB;

    -- grain columns that must never be NULL (subset of v_grains)
    v_required CONSTANT JSONB := '{
        "mart_customer_360":          ["customer_key"],
        "mart_branch_performance":    ["branch_key"],
        "mart_monthly_transactions":  ["month_start", "txn_type", "channel", "merchant_category", "txn_direction"],
        "mart_loan_portfolio":        ["loan_type", "status", "loan_amount_band", "term_band"],
        "mart_card_fraud":            ["month_start", "card_type", "card_category", "card_tier", "merchant_category"],
        "mart_support_performance":   ["month_opened", "issue_type", "status"],
        "mart_kpi_monthly":           ["month_start"]
    }'::JSONB;

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_run_id     BIGINT;
    v_tbl        RECORD;
    v_keys       TEXT[];
    v_req        TEXT[];
    v_col_list   TEXT;
    v_null_cond  TEXT;
    v_null_rows  BIGINT;
    v_dup_keys   BIGINT;
    v_dup_rows   BIGINT;
    v_missing    INT;
    v_checked    INT := 0;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('marts', '02_lp_check_primary_keys.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    FOR v_tbl IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
        ORDER BY c.relname
    LOOP
        -- ---- 1. grain configured ----
        IF NOT v_grains ? v_tbl.relname THEN
            v_violations := v_violations ||
                format('%I.%I: no grain configured', v_schema, v_tbl.relname);
            CONTINUE;
        END IF;

        SELECT array_agg(x)
        INTO v_keys
        FROM jsonb_array_elements_text(v_grains -> v_tbl.relname) AS x;

        -- ---- 2. grain columns exist ----
        SELECT count(*)
        INTO v_missing
        FROM unnest(v_keys) AS k
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = v_tbl.relname
              AND a.attname = k AND a.attnum > 0 AND NOT a.attisdropped
        );

        IF v_missing > 0 THEN
            v_violations := v_violations ||
                format('config error: %I.%I grain column(s) not found: %s',
                       v_schema, v_tbl.relname, array_to_string(v_keys, ', '));
            CONTINUE;
        END IF;

        SELECT string_agg(format('%I', k), ', ')
        INTO v_col_list
        FROM unnest(v_keys) AS k;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%: grain (%)', v_schema, v_tbl.relname, v_col_list;

        -- ---- 3. required grain columns are not NULL ----
        SELECT array_agg(x)
        INTO v_req
        FROM jsonb_array_elements_text(v_required -> v_tbl.relname) AS x;

        SELECT string_agg(format('%I IS NULL', k), ' OR ')
        INTO v_null_cond
        FROM unnest(v_req) AS k;

        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                       v_schema, v_tbl.relname, v_null_cond)
        INTO v_null_rows;

        IF v_null_rows > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with NULL in required grain (%s)',
                       v_schema, v_tbl.relname, v_null_rows,
                       array_to_string(v_req, ', '));
        END IF;

        -- ---- 4. duplicate grain values ----
        EXECUTE format(
            'SELECT count(*), coalesce(sum(n - 1), 0)
             FROM (SELECT count(*) AS n
                   FROM %I.%I
                   GROUP BY %s
                   HAVING count(*) > 1) d',
            v_schema, v_tbl.relname, v_col_list)
        INTO v_dup_keys, v_dup_rows;

        IF v_dup_keys > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s duplicated grain values (%s surplus rows) on (%s)',
                       v_schema, v_tbl.relname, v_dup_keys, v_dup_rows, v_col_list);
        END IF;
    END LOOP;

    -- ---- 5. grain configured for a missing table ----
    FOR v_tbl IN
        SELECT key AS tbl FROM jsonb_each(v_grains)
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = v_tbl.tbl
              AND c.relkind IN ('r', 'p')
        ) THEN
            v_violations := v_violations ||
                format('config error: grain configured for missing table %I.%I',
                       v_schema, v_tbl.tbl);
        END IF;
    END LOOP;

    INSERT INTO audit.dq_violation (run_id, message)
    SELECT v_run_id, unnest(v_violations);

    UPDATE audit.dq_run
    SET finished_at     = now(),
        violation_count = cardinality(v_violations),
        status          = CASE WHEN cardinality(v_violations) = 0
                               THEN 'PASS' ELSE 'FAIL' END
    WHERE run_id = v_run_id;

    COMMIT;

    IF cardinality(v_violations) > 0 THEN
        RAISE EXCEPTION E'Marts grain violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All grain checks passed for schema % (% tables)', v_schema, v_checked;
END $$;
