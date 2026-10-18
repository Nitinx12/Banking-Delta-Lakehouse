-- ============================================================
-- Script Name : 06_lp_check_numeric_ranges.sql
-- Purpose     : Validate numeric columns in the analytics schema
--               (type, nullability, bounds and float money).
--               Fails with a single error that lists all violations.
-- Checks      : 1. Column exists
--               2. Column is numeric, or text holding a number
--               3. Money columns are not float types
--                  (AGENTS.md: never use float for money)
--               4. No NULL values (outside the Unknown member row)
--               5. Text values parse as numbers
--               6. Values within [min, max]
--               7. Values strictly greater than zero when gt0
-- Unknown rows : dimension rows with *_key = -1 are the Unknown
--                 member and are excluded from the checks
-- Note        : This is a PROCEDURE (not a DO block) so it can COMMIT,
--               letting the audit rows survive the final RAISE EXCEPTION.
--               Run with autocommit (psql, pg_cron, or run_analytics_tests.py).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_numeric_ranges()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema             CONSTANT TEXT   := 'analytics';
    v_forbid_float_money CONSTANT BOOLEAN := TRUE;  -- TRUE = flag real/double money columns

    v_ranges CONSTANT JSONB := '{
        "dim_customer.credit_score":               {"min": 300, "max": 900},
        "dim_customer.annual_income":              {"min": 0},
        "dim_employee.salary":                     {"min": 0},
        "dim_card.credit_limit":                   {"min": 0},
        "dim_loan.loan_amount":                    {"min": 0, "gt0": true},
        "dim_loan.interest_rate":                  {"min": 0, "max": 100, "gt0": true},
        "dim_loan.term_months":                    {"min": 1, "max": 600},
        "fact_transactions.amount":                {"gt0": true},
        "fact_card_transactions.amount":           {"gt0": true},
        "fact_loan_payments.amount_paid":          {"min": 0, "gt0": true},
        "fact_loan_payments.principal_component":  {"min": 0},
        "fact_loan_payments.interest_component":   {"min": 0},
        "fact_support_tickets.satisfaction_score": {"min": 1, "max": 5},
        "fact_support_tickets.resolution_days":    {"min": 0}
    }'::JSONB;

    -- money columns that must be numeric (even without a range rule)
    v_money_cols CONSTANT TEXT[] := ARRAY[
        'dim_customer.annual_income', 'dim_employee.salary', 'dim_card.credit_limit',
        'dim_loan.loan_amount', 'dim_loan.interest_rate',
        'fact_transactions.amount', 'fact_card_transactions.amount',
        'fact_loan_payments.amount_paid', 'fact_loan_payments.principal_component',
        'fact_loan_payments.interest_component'
    ]::TEXT[];

    -- NULL allowed: credit limit has no meaning on debit cards
    v_null_ok CONSTANT TEXT[] := ARRAY['dim_card.credit_limit']::TEXT[];

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
    v_money      TEXT;
    v_tbl        TEXT;
    v_col        TEXT;
    v_type_name  TEXT;
    v_atttypid   REGTYPE;
    v_kind       TEXT;
    v_expr       TEXT;
    v_row_filter TEXT;
    v_min        NUMERIC;
    v_max        NUMERIC;
    v_gt0        BOOLEAN;
    v_nulls      BIGINT;
    v_bad        BIGINT;
    v_low        BIGINT;
    v_high       BIGINT;
    v_nonpos     BIGINT;
    v_min_val    NUMERIC;
    v_max_val    NUMERIC;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('analytics', '06_lp_check_numeric_ranges.sql')
    RETURNING run_id INTO v_run_id;

    -- parse a text value to numeric, return NULL when it is not a number
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION pg_temp.anl_try_num(p text)
        RETURNS numeric LANGUAGE sql IMMUTABLE AS $f$
            SELECT CASE WHEN btrim(p) ~ '^-?\d+(\.\d+)?$'
                        THEN btrim(p)::numeric END;
        $f$;
    $fn$;

    -- ---- 3. float money columns ----
    IF v_forbid_float_money THEN
        FOREACH v_money IN ARRAY v_money_cols
        LOOP
            SELECT format_type(a.atttypid, a.atttypmod), a.atttypid::regtype
            INTO v_type_name, v_atttypid
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname  = split_part(v_money, '.', 1)
              AND a.attname  = split_part(v_money, '.', 2)
              AND a.attnum   > 0
              AND NOT a.attisdropped;

            IF NOT FOUND THEN
                v_violations := v_violations ||
                    format('config error: %s not found', v_money);
            ELSIF v_atttypid IN ('float4'::regtype, 'float8'::regtype) THEN
                v_violations := v_violations ||
                    format('%s: money column stored as %s (use numeric)',
                           v_money, v_type_name);
            END IF;
        END LOOP;
    END IF;

    FOR v_rule IN
        SELECT key, value FROM jsonb_each(v_ranges)
    LOOP
        v_tbl := split_part(v_rule.key, '.', 1);
        v_col := split_part(v_rule.key, '.', 2);

        -- ---- 1. column exists ----
        SELECT format_type(a.atttypid, a.atttypmod), a.atttypid::regtype
        INTO v_type_name, v_atttypid
        FROM pg_attribute a
        JOIN pg_class c     ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relname  = v_tbl
          AND a.attname  = v_col
          AND a.attnum   > 0
          AND NOT a.attisdropped;

        IF NOT FOUND THEN
            v_violations := v_violations ||
                format('config error: %s not found', v_rule.key);
            CONTINUE;
        END IF;

        -- ---- 2. type category ----
        v_kind := CASE
            WHEN v_atttypid IN ('int2'::regtype, 'int4'::regtype,
                                'int8'::regtype, 'numeric'::regtype)   THEN 'num'
            WHEN v_atttypid IN ('float4'::regtype, 'float8'::regtype) THEN 'float'
            WHEN v_atttypid IN ('text'::regtype, 'varchar'::regtype,
                                'bpchar'::regtype)                     THEN 'txt'
            ELSE 'other'
        END;

        IF v_kind = 'other' THEN
            v_violations := v_violations ||
                format('%s: expected a numeric column but type is %s',
                       v_rule.key, v_type_name);
            CONTINUE;
        END IF;

        -- ---- 3. float money ----
        IF v_kind = 'float' AND v_forbid_float_money THEN
            v_violations := v_violations ||
                format('%s: money-like column stored as %s (use numeric)',
                       v_rule.key, v_type_name);
        END IF;

        v_expr := CASE v_kind
            WHEN 'txt' THEN format('pg_temp.anl_try_num(%I::text)', v_col)
            ELSE            format('%I', v_col)
        END;

        v_row_filter := CASE WHEN v_unknown_keys ? v_tbl
                             THEN format('%I <> -1', v_unknown_keys ->> v_tbl)
                             ELSE 'TRUE' END;

        v_min := (v_rule.value ->> 'min')::numeric;
        v_max := (v_rule.value ->> 'max')::numeric;
        v_gt0 := coalesce((v_rule.value ->> 'gt0')::boolean, FALSE);

        -- ---- 4-7. one scan per column ----
        EXECUTE format($q$
            WITH s AS MATERIALIZED (
                SELECT %1$s AS v, (%2$I IS NOT NULL) AS has_val
                FROM %3$I.%4$I
                WHERE %8$s
            )
            SELECT count(*) FILTER (WHERE NOT has_val),
                   count(*) FILTER (WHERE has_val AND v IS NULL),
                   count(*) FILTER (WHERE v < %5$L::numeric),
                   count(*) FILTER (WHERE v > %6$L::numeric),
                   count(*) FILTER (WHERE %7$s AND v <= 0),
                   min(v), max(v)
            FROM s
        $q$, v_expr, v_col, v_schema, v_tbl, v_min, v_max, v_gt0::text, v_row_filter)
        INTO v_nulls, v_bad, v_low, v_high, v_nonpos, v_min_val, v_max_val;

        v_checked := v_checked + 1;
        RAISE NOTICE '%: checking numeric range', v_rule.key;

        IF v_nulls > 0 AND v_rule.key <> ALL (v_null_ok) THEN
            v_violations := v_violations ||
                format('%s: %s NULL values', v_rule.key, v_nulls);
        END IF;
        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%s: %s values are not valid numbers', v_rule.key, v_bad);
        END IF;
        IF v_low > 0 THEN
            v_violations := v_violations ||
                format('%s: %s values below %s (min seen %s)',
                       v_rule.key, v_low, v_min, v_min_val);
        END IF;
        IF v_high > 0 THEN
            v_violations := v_violations ||
                format('%s: %s values above %s (max seen %s)',
                       v_rule.key, v_high, v_max, v_max_val);
        END IF;
        IF v_nonpos > 0 THEN
            v_violations := v_violations ||
                format('%s: %s values not greater than zero', v_rule.key, v_nonpos);
        END IF;
    END LOOP;

    DROP FUNCTION pg_temp.anl_try_num(text);

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
        RAISE EXCEPTION E'Analytics numeric range violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All numeric range checks passed: % columns in schema %',
        v_checked, v_schema;
END $$;
