-- ============================================================
-- Script Name : 09_lp_check_duplicate_rows.sql
-- Purpose     : Fail on accidental double-loads and broken
--               business-key uniqueness in the analytics schema.
--               One error lists all violations.
-- Checks      : 1. No exact duplicate rows (same values loaded more
--                  than once, ignoring load metadata)
--               2. Configured business keys are unique
-- Note        : full-row duplicates are detected across every
--               non-metadata column, so two loads of the same row
--               are caught even in different batches
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_duplicate_rows()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'analytics';

    -- business keys that must be unique (columns may be composite)
    v_unique_keys CONSTANT JSONB := '[
        ["dim_customer",    ["customer_id"]],
        ["dim_account",     ["account_id"]],
        ["dim_branch",      ["branch_id"]],
        ["dim_employee",    ["employee_id"]],
        ["dim_card",        ["card_id"]],
        ["dim_loan",        ["loan_id"]],
        ["dim_txn_profile", ["txn_type", "channel", "merchant_category"]],
        ["fact_transactions", ["transaction_id"]],
        ["fact_card_transactions", ["card_txn_id"]],
        ["fact_loan_payments", ["payment_id"]],
        ["fact_support_tickets", ["ticket_id"]]
    ]';

    v_meta_cols CONSTANT TEXT[] := ARRAY['source_batch_id', 'source_row_updated_at', 'row_added_at', 'row_updated_at'];

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_tbl        RECORD;
    v_key        RECORD;
    v_col_list   TEXT;
    v_null_cond  TEXT;
    v_dup_groups BIGINT;
    v_dup_rows   BIGINT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('analytics', '09_lp_check_duplicate_rows.sql')
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

    -- ---- 2. business-key uniqueness ----
    FOR v_key IN
        SELECT e ->> 0 AS tbl, ARRAY(SELECT jsonb_array_elements_text(e -> 1)) AS cols
        FROM jsonb_array_elements(v_unique_keys) AS e
    LOOP
        SELECT string_agg(format('%I', x), ', ' ORDER BY x),
               string_agg(format('%I IS NULL', x), ' OR ')
        INTO v_col_list, v_null_cond
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
                format('config error: %I.%I key column(s) not found: %s',
                       v_schema, v_key.tbl, array_to_string(v_key.cols, ', '));
            CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT count(*), coalesce(sum(n - 1), 0)
            FROM (SELECT count(*) AS n
                  FROM %1$I.%2$I
                  WHERE NOT (%3$s)
                  GROUP BY %4$s
                  HAVING count(*) > 1) d
        $q$, v_schema, v_key.tbl, v_null_cond, v_col_list)
        INTO v_dup_groups, v_dup_rows;

        v_checked := v_checked + 1;

        IF v_dup_groups > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s duplicated key values (%s surplus rows) on (%s)',
                       v_schema, v_key.tbl, v_dup_groups, v_dup_rows, v_col_list);
        END IF;

        -- NULL key values are reported here too (they hide duplicates)
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                       v_schema, v_key.tbl, v_null_cond)
        INTO v_dup_rows;

        IF v_dup_rows > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with NULL business key (%s)',
                       v_schema, v_key.tbl, v_dup_rows, v_col_list);
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
        RAISE EXCEPTION E'Analytics duplicate-row violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All duplicate-row checks passed: % checks in schema %',
        v_checked, v_schema;
END $$;
