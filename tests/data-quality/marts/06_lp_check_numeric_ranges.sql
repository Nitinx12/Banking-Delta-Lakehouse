-- ============================================================
-- Script Name : 06_lp_check_numeric_ranges.sql
-- Purpose     : Validate numeric columns in the marts schema
--               (type, nullability, bounds and float money).
--               Fails with a single error that lists all violations.
-- Checks      : 1. Column exists
--               2. Column is numeric, or text holding a number
--               3. Money columns are not float types
--                  (AGENTS.md: never use float for money)
--               4. No NULL values (outside v_null_ok; aggregate
--                  measures with no underlying rows are NULL)
--               5. Text values parse as numbers
--               6. Values within [min, max]
--               7. Values strictly greater than zero when gt0
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_numeric_ranges(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema             CONSTANT TEXT   := 'marts';
    v_forbid_float_money CONSTANT BOOLEAN := TRUE;

    v_ranges CONSTANT JSONB := '{
        "mart_customer_360.annual_income":                     {"min": 0},
        "mart_customer_360.credit_score":                      {"min": 300, "max": 900},
        "mart_customer_360.loan_to_income_ratio":              {"min": 0},
        "mart_customer_360.avg_satisfaction_score":            {"min": 1, "max": 5},
        "mart_customer_360.avg_resolution_days":               {"min": 0},
        "mart_branch_performance.avg_interest_rate":           {"min": 0, "max": 100},
        "mart_branch_performance.accounts_per_employee":       {"min": 0},
        "mart_branch_performance.late_payment_rate_pct":       {"min": 0, "max": 100},
        "mart_branch_performance.total_salary_cost":           {"min": 0},
        "mart_monthly_transactions.total_amount":              {"min": 0},
        "mart_monthly_transactions.avg_amount":                {"min": 0},
        "mart_monthly_transactions.min_amount":                {"min": 0},
        "mart_monthly_transactions.max_amount":                {"min": 0},
        "mart_loan_portfolio.avg_loan_amount":                 {"min": 0},
        "mart_loan_portfolio.avg_interest_rate":               {"min": 0, "max": 100},
        "mart_loan_portfolio.avg_term_months":                 {"min": 0},
        "mart_loan_portfolio.late_payment_rate_pct":           {"min": 0, "max": 100},
        "mart_loan_portfolio.total_loan_amount":               {"min": 0},
        "mart_card_fraud.total_amount":                        {"min": 0},
        "mart_card_fraud.avg_txn_amount":                      {"min": 0},
        "mart_card_fraud.fraud_amount":                        {"min": 0},
        "mart_card_fraud.fraud_rate_pct":                      {"min": 0, "max": 100},
        "mart_support_performance.resolution_rate_pct":        {"min": 0, "max": 100},
        "mart_support_performance.avg_satisfaction_score":     {"min": 1, "max": 5},
        "mart_support_performance.avg_resolution_days":        {"min": 0},
        "mart_support_performance.max_resolution_days":        {"min": 0},
        "mart_kpi_monthly.year":                               {"min": 1900, "max": 2100},
        "mart_kpi_monthly.quarter":                            {"min": 1, "max": 4},
        "mart_kpi_monthly.avg_interest_rate":                  {"min": 0, "max": 100},
        "mart_kpi_monthly.late_payment_rate_pct":              {"min": 0, "max": 100},
        "mart_kpi_monthly.fraud_rate_pct":                     {"min": 0, "max": 100},
        "mart_kpi_monthly.ticket_resolution_rate_pct":         {"min": 0, "max": 100},
        "mart_kpi_monthly.avg_satisfaction_score":             {"min": 1, "max": 5},
        "mart_kpi_monthly.avg_resolution_days":                {"min": 0},
        "mart_kpi_monthly.avg_txn_amount":                     {"min": 0},
        "mart_kpi_monthly.txn_amount":                         {"min": 0},
        "mart_kpi_monthly.card_spend":                         {"min": 0},
        "mart_kpi_monthly.fraud_amount":                       {"min": 0},
        "mart_kpi_monthly.loan_amount_disbursed":              {"min": 0},
        "mart_kpi_monthly.loan_collections":                   {"min": 0},
        "mart_kpi_monthly.interest_income":                    {"min": 0},
        "mart_kpi_monthly.cumulative_customers":               {"min": 0},
        "mart_kpi_monthly.cumulative_accounts":                {"min": 0},
        "mart_kpi_monthly.cumulative_loan_amount":             {"min": 0},
        "mart_kpi_monthly.txn_amount_mom_pct":                 {"min": -100},
        "mart_kpi_monthly.card_spend_mom_pct":                 {"min": -100},
        "mart_kpi_monthly.loan_collections_mom_pct":           {"min": -100}
    }'::JSONB;

    -- money columns that must be numeric (even without a range rule)
    v_money_cols CONSTANT TEXT[] := ARRAY[
        'mart_branch_performance.total_salary_cost', 'mart_branch_performance.avg_salary',
        'mart_branch_performance.total_loan_amount', 'mart_branch_performance.total_loan_collected',
        'mart_branch_performance.txn_amount', 'mart_customer_360.annual_income',
        'mart_customer_360.total_credit_limit', 'mart_customer_360.total_loan_amount',
        'mart_customer_360.txn_amount', 'mart_customer_360.card_spend',
        'mart_monthly_transactions.total_amount', 'mart_monthly_transactions.avg_amount',
        'mart_monthly_transactions.min_amount', 'mart_monthly_transactions.max_amount',
        'mart_loan_portfolio.total_loan_amount', 'mart_loan_portfolio.avg_loan_amount',
        'mart_loan_portfolio.total_paid', 'mart_loan_portfolio.principal_paid',
        'mart_loan_portfolio.interest_paid', 'mart_loan_portfolio.estimated_outstanding_principal',
        'mart_card_fraud.total_amount', 'mart_card_fraud.avg_txn_amount',
        'mart_card_fraud.fraud_amount', 'mart_kpi_monthly.loan_amount_disbursed',
        'mart_kpi_monthly.loan_collections', 'mart_kpi_monthly.interest_income',
        'mart_kpi_monthly.txn_amount', 'mart_kpi_monthly.card_spend',
        'mart_kpi_monthly.fraud_amount', 'mart_kpi_monthly.cumulative_loan_amount'
    ]::TEXT[];

    -- aggregate measures that are legitimately NULL when there is no
    -- underlying activity (e.g. a customer with no support tickets)
    v_null_ok CONSTANT TEXT[] := ARRAY[
        'mart_customer_360.annual_income', 'mart_customer_360.credit_score',
        'mart_customer_360.loan_to_income_ratio', 'mart_customer_360.avg_satisfaction_score',
        'mart_customer_360.avg_resolution_days',
        'mart_branch_performance.avg_interest_rate',
        'mart_branch_performance.accounts_per_employee',
        'mart_branch_performance.late_payment_rate_pct',
        'mart_loan_portfolio.avg_loan_amount', 'mart_loan_portfolio.avg_interest_rate',
        'mart_loan_portfolio.avg_term_months', 'mart_loan_portfolio.total_loan_amount',
        'mart_loan_portfolio.late_payment_rate_pct',
        'mart_support_performance.avg_satisfaction_score',
        'mart_support_performance.avg_resolution_days',
        'mart_support_performance.max_resolution_days',
        'mart_kpi_monthly.avg_interest_rate', 'mart_kpi_monthly.avg_satisfaction_score',
        'mart_kpi_monthly.avg_resolution_days', 'mart_kpi_monthly.late_payment_rate_pct',
        'mart_kpi_monthly.fraud_rate_pct', 'mart_kpi_monthly.ticket_resolution_rate_pct',
        'mart_kpi_monthly.avg_txn_amount',
        'mart_kpi_monthly.txn_amount_mom_pct',
        'mart_kpi_monthly.card_spend_mom_pct', 'mart_kpi_monthly.loan_collections_mom_pct'
    ]::TEXT[];

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
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('marts', '06_lp_check_numeric_ranges.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    -- parse a text value to numeric, return NULL when it is not a number
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION pg_temp.mrt_try_num(p text)
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
            WHEN 'txt' THEN format('pg_temp.mrt_try_num(%I::text)', v_col)
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

    DROP FUNCTION pg_temp.mrt_try_num(text);

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
        RAISE EXCEPTION E'Marts numeric range violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All numeric range checks passed: % columns in schema %',
        v_checked, v_schema;
END $$;
