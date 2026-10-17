-- ============================================================
-- Script Name : 06_lp_check_numeric_ranges.sql
-- Purpose     : Validate numeric columns in the raw schema
--               (type, nullability, parseability and bounds).
--               Fails with a single error that lists all
--               violations.
-- Checks      : 1. Column exists
--               2. Column is numeric, or text holding a number
--               3. Optional: money columns are not float types
--                  (AGENTS.md: never use float for money)
--               4. No NULL values
--               5. Text values parse as numbers
--               6. Values within [min, max]
--               7. Values strictly greater than zero when gt0
-- Note        : This is a PROCEDURE (not a DO block) so it can COMMIT,
--               letting the audit rows survive the final RAISE EXCEPTION.
--               Run with autocommit (psql, pg_cron, or run_raw_tests.py).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_raw_numeric_ranges()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema             CONSTANT TEXT    := 'raw';
    v_forbid_float_money CONSTANT BOOLEAN := FALSE;  -- TRUE = flag real/double money columns

    v_ranges CONSTANT JSONB := '{
        "customers.credit_score":             {"min": 300, "max": 900},
        "customers.annual_income":            {"min": 0},
        "accounts.balance":                   {"min": 0},
        "cards.credit_limit":                 {"min": 0},
        "employees.salary":                   {"min": 0},
        "loans.loan_amount":                  {"min": 0, "gt0": true},
        "loans.interest_rate":                {"min": 0, "max": 100, "gt0": true},
        "loans.term_months":                  {"min": 1, "max": 600},
        "transactions.amount":                {"gt0": true},
        "card_transactions.amount":           {"gt0": true},
        "loan_payments.amount_paid":          {"min": 0, "gt0": true},
        "loan_payments.principal_component":  {"min": 0},
        "loan_payments.interest_component":   {"min": 0},
        "support_tickets.satisfaction_score": {"min": 1, "max": 5}
    }'::JSONB;

    v_null_ok CONSTANT TEXT[] := ARRAY[]::TEXT[];  -- table.column allowed to be NULL

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_rule       RECORD;
    v_tbl        TEXT;
    v_col        TEXT;
    v_type_name  TEXT;
    v_atttypid   REGTYPE;
    v_kind       TEXT;
    v_expr       TEXT;
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
    VALUES ('raw', '06_lp_check_numeric_ranges.sql')
    RETURNING run_id INTO v_run_id;

    -- parse a text value to numeric, return NULL when it is not a number
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION pg_temp.raw_try_num(p text)
        RETURNS numeric LANGUAGE sql IMMUTABLE AS $f$
            SELECT CASE WHEN btrim(p) ~ '^-?\d+(\.\d+)?$'
                        THEN btrim(p)::numeric END;
        $f$;
    $fn$;

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
          AND c.relname = v_tbl
          AND a.attname = v_col
          AND a.attnum  > 0
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
                format('%s.%s: expected a numeric column but type is %s',
                       v_schema, v_tbl, v_type_name);
            CONTINUE;
        END IF;

        -- ---- 3. float money ----
        IF v_kind = 'float' AND v_forbid_float_money THEN
            v_violations := v_violations ||
                format('%s.%s: money-like column stored as %s (use numeric)',
                       v_schema, v_tbl, v_type_name);
        END IF;

        v_expr := CASE v_kind
            WHEN 'txt' THEN format('pg_temp.raw_try_num(%I::text)', v_col)
            ELSE            format('%I', v_col)
        END;

        v_min := (v_rule.value ->> 'min')::numeric;
        v_max := (v_rule.value ->> 'max')::numeric;
        v_gt0 := coalesce((v_rule.value ->> 'gt0')::boolean, FALSE);

        -- ---- 4-7. one scan per column ----
        EXECUTE format($q$
            WITH s AS MATERIALIZED (
                SELECT %1$s AS v, (%2$I IS NOT NULL) AS has_val
                FROM %3$I.%4$I
            )
            SELECT count(*) FILTER (WHERE NOT has_val),
                   count(*) FILTER (WHERE has_val AND v IS NULL),
                   count(*) FILTER (WHERE v < %5$L::numeric),
                   count(*) FILTER (WHERE v > %6$L::numeric),
                   count(*) FILTER (WHERE %7$s AND v <= 0),
                   min(v), max(v)
            FROM s
        $q$, v_expr, v_col, v_schema, v_tbl, v_min, v_max, v_gt0::text)
        INTO v_nulls, v_bad, v_low, v_high, v_nonpos, v_min_val, v_max_val;

        v_checked := v_checked + 1;
        RAISE NOTICE '%: checking numeric range', v_rule.key;

        IF v_nulls > 0 AND v_rule.key <> ALL (v_null_ok) THEN
            v_violations := v_violations ||
                format('%s.%s: %s NULL values', v_schema, v_tbl, v_nulls);
        END IF;
        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s values are not valid numbers', v_schema, v_tbl, v_bad);
        END IF;
        IF v_low > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s values below %s (min seen %s)',
                       v_schema, v_tbl, v_low, v_min, v_min_val);
        END IF;
        IF v_high > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s values above %s (max seen %s)',
                       v_schema, v_tbl, v_high, v_max, v_max_val);
        END IF;
        IF v_nonpos > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s values not greater than zero', v_schema, v_tbl, v_nonpos);
        END IF;
    END LOOP;

    DROP FUNCTION pg_temp.raw_try_num(text);

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
        RAISE EXCEPTION E'Raw numeric range violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All numeric range checks passed: % columns in schema %',
        v_checked, v_schema;
END $$;
