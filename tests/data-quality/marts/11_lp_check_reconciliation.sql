-- ============================================================
-- Script Name : 11_lp_check_reconciliation.sql
-- Purpose     : Fail when the marts layer does not agree with the
--               analytics layer it was built from. One error lists
--               all violations.
-- Checks      : 1. Row counts match the source dimension for the
--                  grain-carrying marts
--               2. Aggregated measures reconcile to the source
--                  tables (transaction / card / payment / ticket
--                  counts and amount totals), within tolerance
-- Note        : kpi measures are reconciled against the same rows
--               the load keeps (e.g. rows with a non-NULL date); the
--               filter column in each rule makes that explicit
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_reconciliation()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'marts';

    -- [mart_table, source_schema, source_table]
    v_row_pairs CONSTANT JSONB := '[
        ["mart_customer_360",       "analytics", "dim_customer"],
        ["mart_branch_performance", "analytics", "dim_branch"]
    ]'::JSONB;

    -- [mart_table, mart_measure, source_schema, source_table,
    --  source_measure ('*' = count(*)), source_filter, tolerance]
    v_measures CONSTANT JSONB := '[
        ["mart_monthly_transactions", "txn_count",        "analytics", "fact_transactions",      "*",         "TRUE", 0.01],
        ["mart_monthly_transactions", "total_amount",     "analytics", "fact_transactions",      "amount",    "TRUE", 0.01],
        ["mart_card_fraud",           "txn_count",        "analytics", "fact_card_transactions", "*",         "TRUE", 0.01],
        ["mart_card_fraud",           "total_amount",     "analytics", "fact_card_transactions", "amount",    "TRUE", 0.01],
        ["mart_card_fraud",           "fraud_amount",     "analytics", "fact_card_transactions", "amount",    "is_fraud::int = 1", 0.01],
        ["mart_loan_portfolio",       "loan_count",       "analytics", "dim_loan",               "*",         "TRUE", 0.01],
        ["mart_loan_portfolio",       "total_loan_amount","analytics", "dim_loan",               "loan_amount", "TRUE", 0.01],
        ["mart_loan_portfolio",       "total_paid",       "analytics", "fact_loan_payments",     "amount_paid", "TRUE", 0.01],
        ["mart_support_performance",  "ticket_count",     "analytics", "fact_support_tickets",   "*",         "TRUE", 0.01],
        ["mart_customer_360",         "txn_count",        "analytics", "fact_transactions",      "*",         "TRUE", 0.01],
        ["mart_customer_360",         "card_txn_count",   "analytics", "fact_card_transactions", "*",         "TRUE", 0.01],
        ["mart_customer_360",         "total_tickets",    "analytics", "fact_support_tickets",   "*",         "TRUE", 0.01],
        ["mart_kpi_monthly",          "txn_count",        "analytics", "fact_transactions",      "*",         "txn_date IS NOT NULL", 0.01],
        ["mart_kpi_monthly",          "card_txn_count",   "analytics", "fact_card_transactions", "*",         "txn_date IS NOT NULL", 0.01],
        ["mart_kpi_monthly",          "loan_collections", "analytics", "fact_loan_payments",     "amount_paid", "payment_date IS NOT NULL", 0.01],
        ["mart_kpi_monthly",          "new_customers",    "analytics", "dim_customer",           "*",         "join_date IS NOT NULL", 0.01]
    ]'::JSONB;

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_rule       RECORD;
    v_m_rows     BIGINT;
    v_s_rows     BIGINT;
    v_m_sum      NUMERIC;
    v_s_sum      NUMERIC;
    v_tol        NUMERIC;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('marts', '11_lp_check_reconciliation.sql')
    RETURNING run_id INTO v_run_id;

    -- ---- 1. row-count coverage ----
    FOR v_rule IN
        SELECT e ->> 0 AS mart_tbl, e ->> 1 AS src_schema, e ->> 2 AS src_tbl
        FROM jsonb_array_elements(v_row_pairs) AS e
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I', v_schema, v_rule.mart_tbl)
        INTO v_m_rows;
        EXECUTE format('SELECT count(*) FROM %I.%I', v_rule.src_schema, v_rule.src_tbl)
        INTO v_s_rows;

        v_checked := v_checked + 1;
        RAISE NOTICE '% vs %.%: % / % rows', v_rule.mart_tbl, v_rule.src_schema,
            v_rule.src_tbl, v_m_rows, v_s_rows;

        IF v_m_rows <> v_s_rows THEN
            v_violations := v_violations ||
                format('%I.%I has %s rows but %I.%I has %s',
                       v_schema, v_rule.mart_tbl, v_m_rows,
                       v_rule.src_schema, v_rule.src_tbl, v_s_rows);
        END IF;
    END LOOP;

    -- ---- 2. aggregated measure totals ----
    FOR v_rule IN
        SELECT e ->> 0 AS mart_tbl, e ->> 1 AS mart_measure,
               e ->> 2 AS src_schema, e ->> 3 AS src_tbl,
               e ->> 4 AS src_measure, e ->> 5 AS src_filter,
               (e ->> 6)::numeric AS tol
        FROM jsonb_array_elements(v_measures) AS e
    LOOP
        EXECUTE format('SELECT coalesce(sum(%I), 0) FROM %I.%I',
                       v_rule.mart_measure, v_schema, v_rule.mart_tbl)
        INTO v_m_sum;

        IF v_rule.src_measure = '*' THEN
            EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                           v_rule.src_schema, v_rule.src_tbl, v_rule.src_filter)
            INTO v_s_sum;
        ELSE
            EXECUTE format('SELECT coalesce(sum(%I), 0) FROM %I.%I WHERE %s',
                           v_rule.src_measure, v_rule.src_schema, v_rule.src_tbl,
                           v_rule.src_filter)
            INTO v_s_sum;
        END IF;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.% vs %.%: % / %', v_rule.mart_tbl, v_rule.mart_measure,
            v_rule.src_schema, v_rule.src_tbl, v_m_sum, v_s_sum;

        IF abs(v_m_sum - v_s_sum) > v_rule.tol THEN
            v_violations := v_violations ||
                format('%I.%I.%I sums to %s but %I.%I.%s sums to %s (tolerance %s)',
                       v_schema, v_rule.mart_tbl, v_rule.mart_measure, v_m_sum,
                       v_rule.src_schema, v_rule.src_tbl, v_rule.src_measure,
                       v_s_sum, v_rule.tol);
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
        RAISE EXCEPTION E'Marts reconciliation violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All reconciliation checks passed: % checks against analytics', v_checked;
END $$;
