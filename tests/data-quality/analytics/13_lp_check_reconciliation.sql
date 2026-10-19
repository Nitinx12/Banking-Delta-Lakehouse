-- ============================================================
-- Script Name : 13_lp_check_reconciliation.sql
-- Purpose     : Fail when the analytics layer does not agree with
--               the staging layer it was built from. One error lists
--               all violations.
-- Checks      : 1. Row counts match (dimensions exclude the Unknown
--                  member, *key = -1)
--               2. Every staging key exists in analytics and vice
--                  versa (no dropped or invented rows)
--               3. Measure totals match within tolerance
--               4. Row-level values match for the compared columns
--                  (dim_customer.gender is excluded on purpose: the
--                   analytics load corrects it from the name list)
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_reconciliation()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'analytics';

    -- [analytics_table, staging_table, analytics_key, staging_key, kind]
    v_count_pairs CONSTANT JSONB := '[
        ["dim_customer",         "customers",         "customer_id",    "customer_id",    "dim"],
        ["dim_account",          "accounts",          "account_id",     "account_id",     "dim"],
        ["dim_branch",           "branches",          "branch_id",      "branch_id",      "dim"],
        ["dim_employee",         "employees",         "employee_id",    "employee_id",    "dim"],
        ["dim_card",             "cards",             "card_id",        "card_id",        "dim"],
        ["dim_loan",             "loans",             "loan_id",        "loan_id",        "dim"],
        ["fact_transactions",    "transactions",      "transaction_id", "transaction_id", "fact"],
        ["fact_card_transactions","card_transactions","card_txn_id",    "card_txn_id",    "fact"],
        ["fact_loan_payments",   "loan_payments",     "payment_id",     "payment_id",     "fact"],
        ["fact_support_tickets", "support_tickets",   "ticket_id",      "ticket_id",      "fact"]
    ]'::JSONB;

    -- [analytics_table, staging_table, analytics_measure, staging_measure, tolerance]
    v_measures CONSTANT JSONB := '[
        ["fact_transactions",      "transactions",      "amount",      "amount",      0.01],
        ["fact_card_transactions", "card_transactions", "amount",      "amount",      0.01],
        ["fact_loan_payments",     "loan_payments",     "amount_paid", "amount_paid", 0.01]
    ]';

    -- [analytics_table, staging_table, analytics_key, staging_key, {analytics_col: staging_col}]
    v_row_compare CONSTANT JSONB := '[
        ["dim_customer",         "customers",         "customer_id",    "customer_id",
         {"customer_name":"customer_name","date_of_birth":"date_of_birth","annual_income":"annual_income","credit_score":"credit_score"}],
        ["dim_account",          "accounts",          "account_id",     "account_id",
         {"account_type":"account_type","status":"status","open_date":"open_date","customer_id":"customer_id"}],
        ["dim_branch",           "branches",          "branch_id",      "branch_id",
         {"branch_name":"branch_name","state":"state","ifsc_code":"ifsc_code"}],
        ["dim_employee",         "employees",         "employee_id",    "employee_id",
         {"role":"role","hire_date":"hire_date","salary":"salary","branch_id":"branch_id"}],
        ["dim_card",             "cards",             "card_id",        "card_id",
         {"card_type":"card_type","status":"status","expiry_date":"expiry_date","credit_limit":"credit_limit"}],
        ["dim_loan",             "loans",             "loan_id",        "loan_id",
         {"loan_amount":"loan_amount","status":"status","term_months":"term_months","customer_id":"customer_id"}],
        ["fact_transactions",    "transactions",      "transaction_id", "transaction_id",
         {"amount":"amount","txn_date":"txn_date"}],
        ["fact_card_transactions","card_transactions","card_txn_id",    "card_txn_id",
         {"amount":"amount","txn_date":"txn_date","is_fraud":"is_fraud"}],
        ["fact_loan_payments",   "loan_payments",     "payment_id",     "payment_id",
         {"amount_paid":"amount_paid","payment_date":"payment_date","amount_check":"amount_check"}],
        ["fact_support_tickets", "support_tickets",   "ticket_id",      "ticket_id",
         {"status":"status","date_opened":"date_opened","date_resolved":"date_resolved","satisfaction_score":"satisfaction_score"}]
    ]'::JSONB;

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_rule       RECORD;
    v_pair       RECORD;
    v_col        TEXT;
    v_scol       TEXT;
    v_filter     TEXT;
    v_a_rows     BIGINT;
    v_s_rows     BIGINT;
    v_missing    BIGINT;
    v_extra      BIGINT;
    v_a_sum      NUMERIC;
    v_s_sum      NUMERIC;
    v_mismatch   BIGINT;
    v_compare    TEXT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('analytics', '13_lp_check_reconciliation.sql')
    RETURNING run_id INTO v_run_id;

    -- ---- 1-2. row counts and key coverage ----
    FOR v_rule IN
        SELECT e ->> 0 AS a_tbl, e ->> 1 AS s_tbl,
               e ->> 2 AS a_key, e ->> 3 AS s_key, e ->> 4 AS kind
        FROM jsonb_array_elements(v_count_pairs) AS e
    LOOP
        v_filter := CASE WHEN v_rule.kind = 'dim'
                         THEN format('%I <> -1', v_rule.a_key)
                         ELSE 'TRUE' END;

        EXECUTE format($q$
            WITH a AS (
                SELECT %2$I AS k FROM %1$I.%3$I WHERE %4$s
            ), s AS (
                SELECT %5$I AS k FROM %6$I.%7$I
            )
            SELECT (SELECT count(*) FROM a),
                   (SELECT count(*) FROM s),
                   (SELECT count(*) FROM s x WHERE NOT EXISTS (SELECT 1 FROM a WHERE a.k = x.k)),
                   (SELECT count(*) FROM a x WHERE NOT EXISTS (SELECT 1 FROM s WHERE s.k = x.k))
        $q$, v_schema, v_rule.a_key, v_rule.a_tbl, v_filter, v_rule.s_key, 'staging', v_rule.s_tbl)
        INTO v_a_rows, v_s_rows, v_missing, v_extra;

        v_checked := v_checked + 1;
        RAISE NOTICE '% vs %: analytics=% staging=% missing=% extra=%',
            v_rule.a_tbl, v_rule.s_tbl, v_a_rows, v_s_rows, v_missing, v_extra;

        IF v_a_rows <> v_s_rows THEN
            v_violations := v_violations ||
                format('%I.%I has %s rows but staging.%I has %s',
                       v_schema, v_rule.a_tbl, v_a_rows, v_rule.s_tbl, v_s_rows);
        END IF;
        IF v_missing > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s staging.%I rows are missing from analytics',
                       v_schema, v_rule.a_tbl, v_missing, v_rule.s_tbl);
        END IF;
        IF v_extra > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows have no match in staging.%I',
                       v_schema, v_rule.a_tbl, v_extra, v_rule.s_tbl);
        END IF;
    END LOOP;

    -- ---- 3. measure totals ----
    FOR v_rule IN
        SELECT e ->> 0 AS a_tbl, e ->> 1 AS s_tbl,
               e ->> 2 AS a_col, e ->> 3 AS s_col,
               (e ->> 4)::numeric AS tol
        FROM jsonb_array_elements(v_measures) AS e
    LOOP
        EXECUTE format('SELECT sum(%I) FROM %I.%I', v_rule.a_col, v_schema, v_rule.a_tbl)
        INTO v_a_sum;
        EXECUTE format('SELECT sum(%I) FROM %I.%I', v_rule.s_col, 'staging', v_rule.s_tbl)
        INTO v_s_sum;

        v_checked := v_checked + 1;

        IF abs(coalesce(v_a_sum, 0) - coalesce(v_s_sum, 0)) > v_rule.tol THEN
            v_violations := v_violations ||
                format('%I.%I.%s sums to %s but staging.%I.%s sums to %s (tolerance %s)',
                       v_schema, v_rule.a_tbl, v_rule.a_col, v_a_sum,
                       v_rule.s_tbl, v_rule.s_col, v_s_sum, v_rule.tol);
        END IF;
    END LOOP;

    -- ---- 4. row-level value agreement ----
    FOR v_rule IN
        SELECT e ->> 0 AS a_tbl, e ->> 1 AS s_tbl,
               e ->> 2 AS a_key, e ->> 3 AS s_key, e -> 4 AS cols
        FROM jsonb_array_elements(v_row_compare) AS e
    LOOP
        v_compare := '';
        FOR v_col, v_scol IN SELECT key, value #>> '{}' FROM jsonb_each(v_rule.cols)
        LOOP
            v_compare := v_compare ||
                CASE WHEN v_compare = '' THEN '' ELSE ' OR ' END ||
                format('a.%I IS DISTINCT FROM s.%I', v_col, v_scol);
        END LOOP;

        EXECUTE format($q$
            SELECT count(*)
            FROM %1$I.%2$I a
            JOIN %3$I.%4$I s ON s.%5$I = a.%6$I
            WHERE %7$s
        $q$, v_schema, v_rule.a_tbl, 'staging', v_rule.s_tbl, v_rule.s_key,
             v_rule.a_key, v_compare)
        INTO v_mismatch;

        v_checked := v_checked + 1;
        RAISE NOTICE '% vs %: % value mismatches', v_rule.a_tbl, v_rule.s_tbl, v_mismatch;

        IF v_mismatch > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows differ from staging.%I on %s',
                       v_schema, v_rule.a_tbl, v_mismatch, v_rule.s_tbl,
                       (SELECT string_agg(x.k, ', ' ORDER BY x.k)
                        FROM jsonb_each(v_rule.cols) AS x(k)));
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
        RAISE EXCEPTION E'Analytics reconciliation violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All reconciliation checks passed: % checks against staging', v_checked;
END $$;
