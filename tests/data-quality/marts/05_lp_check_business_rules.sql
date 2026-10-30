-- ============================================================
-- Script Name : 05_lp_check_business_rules.sql
-- Purpose     : Validate cross-column logical consistency in the
--               marts schema. Fails with a single error that lists
--               all violations.
-- Checks      : Each rule is a condition that must never be TRUE;
--               the count of matching rows is reported per rule
--               (e.g. active accounts never exceed total accounts,
--               fraud counts never exceed transaction counts,
--               average amounts stay within their min / max)
-- Note        : single-column bounds (rates 0-100, credit score,
--               satisfaction score, ...) live in
--               06_lp_check_numeric_ranges.sql
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_business_rules(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'marts';

    -- [table, bad-row condition, description]
    v_rules CONSTANT JSONB := '[
        ["mart_customer_360", "active_accounts > total_accounts",
         "active accounts exceed total accounts"],
        ["mart_customer_360", "active_cards > total_cards",
         "active cards exceed total cards"],
        ["mart_customer_360", "active_loans > total_loans",
         "active loans exceed total loans"],
        ["mart_customer_360", "card_fraud_txn_count > card_txn_count",
         "fraud card transactions exceed card transactions"],
        ["mart_customer_360", "resolved_tickets > total_tickets",
         "resolved tickets exceed total tickets"],
        ["mart_customer_360", "products_held < 0 OR products_held > 3",
         "products held outside 0-3"],
        ["mart_branch_performance", "active_accounts > total_accounts",
         "active accounts exceed total accounts"],
        ["mart_branch_performance", "active_loans > total_loans",
         "active loans exceed total loans"],
        ["mart_monthly_transactions", "active_accounts > txn_count",
         "active accounts exceed transaction count"],
        ["mart_monthly_transactions", "avg_amount < min_amount OR avg_amount > max_amount",
         "average amount outside min / max"],
        ["mart_monthly_transactions", "min_amount > max_amount",
         "minimum amount above maximum amount"],
        ["mart_card_fraud", "fraud_txn_count > txn_count",
         "fraud transactions exceed transaction count"],
        ["mart_card_fraud", "fraud_amount > total_amount",
         "fraud amount exceeds total amount"],
        ["mart_card_fraud", "active_cards > txn_count",
         "active cards exceed transaction count"],
        ["mart_loan_portfolio", "late_payments > payment_count",
         "late payments exceed payment count"],
        ["mart_loan_portfolio", "principal_paid > total_paid",
         "principal paid exceeds total paid"],
        ["mart_loan_portfolio", "interest_paid > total_paid",
         "interest paid exceeds total paid"],
        ["mart_support_performance", "resolved_count > ticket_count",
         "resolved tickets exceed ticket count"],
        ["mart_support_performance", "customers_affected > ticket_count",
         "customers affected exceed ticket count"],
        ["mart_support_performance", "low_satisfaction_count > ticket_count",
         "low satisfaction tickets exceed ticket count"],
        ["mart_kpi_monthly", "fraud_txn_count > card_txn_count",
         "fraud transactions exceed card transactions"],
        ["mart_kpi_monthly", "tickets_resolved > tickets_opened",
         "tickets resolved exceed tickets opened"],
        ["mart_loan_vintage", "late_payments > payment_count",
         "late payments exceed payment count"],
        ["mart_loan_vintage", "principal_paid > amount_paid",
         "principal paid exceeds amount paid"],
        ["mart_loan_vintage", "interest_paid > amount_paid",
         "interest paid exceeds amount paid"],
        ["mart_loan_vintage", "loans_with_payments > payment_count",
         "loans with payments exceed payment count"]
    ]'::JSONB;

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_rule       RECORD;
    v_bad        BIGINT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('marts', '05_lp_check_business_rules.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    FOR v_rule IN
        SELECT e ->> 0 AS tbl, e ->> 1 AS cond, e ->> 2 AS msg
        FROM jsonb_array_elements(v_rules) AS e
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = v_rule.tbl
              AND c.relkind IN ('r', 'p')
        ) THEN
            v_violations := v_violations ||
                format('config error: table %I.%I not found', v_schema, v_rule.tbl);
            CONTINUE;
        END IF;

        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                       v_schema, v_rule.tbl, v_rule.cond)
        INTO v_bad;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%: % violations (%)',
            v_schema, v_rule.tbl, v_rule.msg, v_bad;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows where %s', v_schema, v_rule.tbl, v_bad, v_rule.msg);
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
        RAISE EXCEPTION E'Marts business rule violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All business rule checks passed: % rules in schema %',
        v_checked, v_schema;
END $$;
