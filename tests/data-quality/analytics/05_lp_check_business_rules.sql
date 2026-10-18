-- ============================================================
-- Script Name : 05_lp_check_business_rules.sql
-- Purpose     : Validate logical/temporal consistency on the
--               analytics schema. Fails with a single error that
--               lists all violations.
-- Checks      : 1. Intra-table date order (later >= earlier)
--               2. Arithmetic identity (components sum to total)
--               3. Difference identity (resolution_days =
--                  date_resolved - date_opened)
--               4. Derived flags agree with their status column
--                  (is_active / is_resolved)
-- Unknown rows : dimension rows with *_key = -1 are excluded
-- Note        : This is a PROCEDURE (not a DO block) so it can COMMIT,
--               letting the audit rows survive the final RAISE EXCEPTION.
--               Run with autocommit (psql, pg_cron, or run_analytics_tests.py).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_business_rules()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'analytics';

    -- [table, earlier_col, later_col] : later must be >= earlier
    v_order_rules CONSTANT JSONB := '[
        ["dim_customer",        "date_of_birth", "join_date"],
        ["dim_card",            "issue_date",    "expiry_date"],
        ["dim_loan",            "start_date",    "maturity_date"],
        ["fact_support_tickets","date_opened",   "date_resolved"]
    ]';

    -- [table, [component columns], total column, tolerance, scope condition]
    v_sum_rules CONSTANT JSONB := '[
        ["fact_loan_payments", ["principal_component", "interest_component"], "amount_paid", 0.01, "TRUE"]
    ]';

    -- [table, value column, positive date, negative date]
    v_diff_rules CONSTANT JSONB := '[
        ["fact_support_tickets", "resolution_days", "date_resolved", "date_opened"]
    ]';

    -- [table, flag column, expected condition]
    v_flag_rules CONSTANT JSONB := '[
        ["dim_account",         "is_active",   "status = ''Active''"],
        ["dim_card",            "is_active",   "status = ''Active''"],
        ["dim_loan",            "is_active",   "status = ''Active''"],
        ["fact_support_tickets","is_resolved", "status = ''Resolved''"]
    ]';

    -- dimension tables and the surrogate key that marks the Unknown member
    v_unknown_keys CONSTANT JSONB := '{
        "dim_account":  "account_key",
        "dim_branch":   "branch_key",
        "dim_card":     "card_key",
        "dim_customer": "customer_key",
        "dim_employee": "employee_key",
        "dim_loan":     "loan_key",
        "dim_txn_profile": "txn_profile_key"
    }'::JSONB;

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_rule       RECORD;
    v_bad        BIGINT;
    v_examples   TEXT;
    v_parts      TEXT;
    v_tol        NUMERIC;
    v_cond       TEXT;
    v_filter     TEXT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('analytics', '05_lp_check_business_rules.sql')
    RETURNING run_id INTO v_run_id;

    -- ---- 1. intra-table date order ----
    FOR v_rule IN
        SELECT e ->> 0 AS tbl, e ->> 1 AS earlier, e ->> 2 AS later
        FROM jsonb_array_elements(v_order_rules) AS e
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = v_rule.tbl
              AND a.attname = v_rule.earlier AND a.attnum > 0 AND NOT a.attisdropped
        ) OR NOT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = v_rule.tbl
              AND a.attname = v_rule.later AND a.attnum > 0 AND NOT a.attisdropped
        ) THEN
            v_violations := v_violations ||
                format('config error: %s.%s date column(s) not found',
                       v_rule.tbl, v_rule.earlier || ', ' || v_rule.later);
            CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT count(*),
                   array_to_string((array_agg(DISTINCT %1$I::text))[1:3], ', ')
            FROM %2$I.%3$I
            WHERE %1$I IS NOT NULL AND %4$I IS NOT NULL AND %1$I < %4$I
        $q$, v_rule.later, v_schema, v_rule.tbl, v_rule.earlier)
        INTO v_bad, v_examples;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%: % before % : % violations',
            v_schema, v_rule.tbl, v_rule.later, v_rule.earlier, v_bad;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s rows where %s < %s (e.g. %s)',
                       v_schema, v_rule.tbl, v_bad, v_rule.later, v_rule.earlier, v_examples);
        END IF;
    END LOOP;

    -- ---- 2. arithmetic identity: components sum to total ----
    FOR v_rule IN
        SELECT e ->> 0 AS tbl, e -> 1 AS parts, e ->> 2 AS total,
               (e ->> 3)::numeric AS tol, e ->> 4 AS cond
        FROM jsonb_array_elements(v_sum_rules) AS e
    LOOP
        SELECT string_agg(format('coalesce(%I, 0)', x), ' + ')
        INTO v_parts
        FROM jsonb_array_elements_text(v_rule.parts) AS x;

        v_tol  := coalesce(v_rule.tol, 0.01);
        v_cond := coalesce(nullif(v_rule.cond, ''), 'TRUE');

        EXECUTE format($q$
            SELECT count(*)
            FROM %1$I.%2$I
            WHERE %3$I IS NOT NULL AND abs(%3$I - (%4$s)) > %5$L
              AND %6$s
        $q$, v_schema, v_rule.tbl, v_rule.total, v_parts, v_tol, v_cond)
        INTO v_bad;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%: sum(%) vs % : % violations',
            v_schema, v_rule.tbl, v_parts, v_rule.total, v_bad;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s rows where %s <> sum(%s) beyond %s',
                       v_schema, v_rule.tbl, v_bad, v_rule.total, v_parts, v_tol);
        END IF;
    END LOOP;

    -- ---- 3. difference identity: date delta equals the measure ----
    FOR v_rule IN
        SELECT e ->> 0 AS tbl, e ->> 1 AS val_col,
               e ->> 2 AS pos_col, e ->> 3 AS neg_col
        FROM jsonb_array_elements(v_diff_rules) AS e
    LOOP
        EXECUTE format($q$
            SELECT count(*)
            FROM %1$I.%2$I
            WHERE %3$I IS NOT NULL AND %4$I IS NOT NULL AND %5$I IS NOT NULL
              AND %5$I <> (%4$I - %3$I)
        $q$, v_schema, v_rule.tbl, v_rule.val_col, v_rule.pos_col, v_rule.neg_col)
        INTO v_bad;

        v_checked := v_checked + 1;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s rows where %s <> %s - %s',
                       v_schema, v_rule.tbl, v_bad, v_rule.val_col,
                       v_rule.pos_col, v_rule.neg_col);
        END IF;
    END LOOP;

    -- ---- 4. derived flags vs their status column ----
    FOR v_rule IN
        SELECT e ->> 0 AS tbl, e ->> 1 AS flag_col, e ->> 2 AS cond
        FROM jsonb_array_elements(v_flag_rules) AS e
    LOOP
        v_filter := CASE WHEN v_unknown_keys ? v_rule.tbl
                         THEN format('%I <> -1', v_unknown_keys ->> v_rule.tbl)
                         ELSE 'TRUE' END;

        EXECUTE format($q$
            SELECT count(*)
            FROM %1$I.%2$I
            WHERE %3$s AND %4$I IS DISTINCT FROM (%5$s)
        $q$, v_schema, v_rule.tbl, v_filter, v_rule.flag_col, v_rule.cond)
        INTO v_bad;

        v_checked := v_checked + 1;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s rows where %s <> (%s)',
                       v_schema, v_rule.tbl, v_bad, v_rule.flag_col, v_rule.cond);
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
        RAISE EXCEPTION E'Analytics business rule violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All business rule checks passed: % rules in schema %',
        v_checked, v_schema;
END $$;
