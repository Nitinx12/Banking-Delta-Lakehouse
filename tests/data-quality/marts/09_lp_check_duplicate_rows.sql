-- ============================================================
-- Script Name : 09_lp_check_duplicate_rows.sql
-- Purpose     : Fail on accidental double-refreshes and broken grain
--               uniqueness in the marts schema. One error lists all
--               violations.
-- Checks      : 1. No exact duplicate rows (same values, ignoring
--                  mart_refreshed_at)
--               2. The configured grain is unique
-- Note        : the grain here matches 02_lp_check_primary_keys.sql;
--               NULLs in nullable grain columns (region, state, ...)
--               are allowed and group together, which is the correct
--               uniqueness semantics for a GROUP BY aggregate
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_duplicate_rows(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'marts';

    -- grain that must be unique (columns may be composite)
    v_unique_keys CONSTANT JSONB := '[
        ["mart_customer_360",        ["customer_key"]],
        ["mart_branch_performance",  ["branch_key"]],
        ["mart_monthly_transactions", ["month_start", "txn_type", "channel", "merchant_category", "txn_direction", "region", "state"]],
        ["mart_loan_portfolio",      ["loan_type", "status", "loan_amount_band", "term_band", "start_year"]],
        ["mart_card_fraud",          ["month_start", "card_type", "card_category", "card_tier", "merchant_category"]],
        ["mart_support_performance", ["month_opened", "issue_type", "status", "customer_state", "income_band"]],
        ["mart_kpi_monthly",         ["month_start"]]
    ]';

    v_meta_cols CONSTANT TEXT[] := ARRAY['mart_refreshed_at'];

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_tbl        RECORD;
    v_key        RECORD;
    v_col_list   TEXT;
    v_dup_groups BIGINT;
    v_dup_rows   BIGINT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('marts', '09_lp_check_duplicate_rows.sql', p_pipeline_run_id)
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
        -- ---- 1. exact duplicate rows (all non-metadata columns) ----
        SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum)
        INTO v_col_list
        FROM pg_attribute a
        JOIN pg_class c     ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relname = v_tbl.relname
          AND a.attnum  > 0
          AND NOT a.attisdropped
          AND a.attname <> ALL (v_meta_cols);

        IF v_col_list IS NULL THEN
            CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT count(*), coalesce(sum(n - 1), 0)
            FROM (SELECT count(*) AS n
                  FROM %I.%I
                  GROUP BY %s
                  HAVING count(*) > 1) d
        $q$, v_schema, v_tbl.relname, v_col_list)
        INTO v_dup_groups, v_dup_rows;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%: % duplicate-row groups', v_schema, v_tbl.relname, v_dup_groups;

        IF v_dup_groups > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s surplus rows across %s duplicated row-groups',
                       v_schema, v_tbl.relname, v_dup_rows, v_dup_groups);
        END IF;
    END LOOP;

    -- ---- 2. grain uniqueness ----
    FOR v_key IN
        SELECT e ->> 0 AS tbl, ARRAY(SELECT jsonb_array_elements_text(e -> 1)) AS cols
        FROM jsonb_array_elements(v_unique_keys) AS e
    LOOP
        SELECT string_agg(format('%I', x), ', ' ORDER BY x)
        INTO v_col_list
        FROM unnest(v_key.cols) AS x;

        IF NOT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_key.tbl
              AND a.attname = ANY (v_key.cols)
              AND a.attnum  > 0
              AND NOT a.attisdropped
        ) THEN
            v_violations := v_violations ||
                format('config error: %I.%I grain column(s) not found: %s',
                       v_schema, v_key.tbl, array_to_string(v_key.cols, ', '));
            CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT count(*), coalesce(sum(n - 1), 0)
            FROM (SELECT count(*) AS n
                  FROM %I.%I
                  GROUP BY %s
                  HAVING count(*) > 1) d
        $q$, v_schema, v_key.tbl, v_col_list)
        INTO v_dup_groups, v_dup_rows;

        v_checked := v_checked + 1;

        IF v_dup_groups > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s duplicated grain values (%s surplus rows) on (%s)',
                       v_schema, v_key.tbl, v_dup_groups, v_dup_rows, v_col_list);
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
        RAISE EXCEPTION E'Marts duplicate-row violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All duplicate-row checks passed: % checks in schema %',
        v_checked, v_schema;
END $$;
