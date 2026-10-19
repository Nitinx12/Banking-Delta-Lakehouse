-- ============================================================
-- Script Name : 07_lp_check_schema_contract.sql
-- Purpose     : Fail if any marts table has drifted from its agreed
--               column contract. One error lists all violations.
-- Checks      : 1. Expected table exists
--               2. Every expected column exists
--               3. Column type family matches the contract
--               4. No unexpected data columns
--               5. Every marts table has a contract entry
-- Families    : int, num, text, date, bool, any
-- Note        : mart_refreshed_at is load metadata and is exempt
--               from the extra-column check
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_schema_contract()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema       CONSTANT TEXT    := 'marts';
    v_forbid_extra CONSTANT BOOLEAN := TRUE;

    v_contract CONSTANT JSONB := '{
        "mart_customer_360": {"customer_key":"int","customer_id":"int","customer_name":"text","gender":"text","age_band":"text","city":"text","state":"text","occupation":"text","income_band":"text","annual_income":"num","join_date":"date","credit_score":"int","credit_band":"text","total_accounts":"int","active_accounts":"int","total_cards":"int","active_cards":"int","total_credit_limit":"num","total_loans":"int","active_loans":"int","total_loan_amount":"num","loan_to_income_ratio":"num","txn_count":"int","txn_amount":"num","last_txn_date":"date","card_txn_count":"int","card_spend":"num","card_fraud_txn_count":"int","total_tickets":"int","resolved_tickets":"int","avg_resolution_days":"num","avg_satisfaction_score":"num","products_held":"int"},
        "mart_branch_performance": {"branch_key":"int","branch_id":"int","branch_name":"text","city":"text","state":"text","region":"text","ifsc_code":"text","opened_year":"int","branch_age_band":"text","total_customers":"int","total_accounts":"int","active_accounts":"int","employee_count":"int","total_salary_cost":"num","avg_salary":"num","total_loans":"int","active_loans":"int","total_loan_amount":"num","avg_interest_rate":"num","total_loan_collected":"num","late_payment_rate_pct":"num","txn_count":"int","txn_amount":"num","accounts_per_employee":"num"},
        "mart_monthly_transactions": {"month_start":"date","txn_type":"text","channel":"text","merchant_category":"text","txn_direction":"text","region":"text","state":"text","txn_count":"int","active_accounts":"int","total_amount":"num","avg_amount":"num","min_amount":"num","max_amount":"num"},
        "mart_loan_portfolio": {"loan_type":"text","status":"text","loan_amount_band":"text","term_band":"text","start_year":"int","loan_count":"int","total_loan_amount":"num","avg_loan_amount":"num","avg_interest_rate":"num","avg_term_months":"num","payment_count":"num","total_paid":"num","principal_paid":"num","interest_paid":"num","late_payments":"num","late_payment_rate_pct":"num","estimated_outstanding_principal":"num"},
        "mart_card_fraud": {"month_start":"date","card_type":"text","card_category":"text","card_tier":"text","merchant_category":"text","txn_count":"int","active_cards":"int","total_amount":"num","avg_txn_amount":"num","fraud_txn_count":"int","fraud_amount":"num","fraud_rate_pct":"num"},
        "mart_support_performance": {"month_opened":"date","issue_type":"text","status":"text","customer_state":"text","income_band":"text","ticket_count":"int","customers_affected":"int","resolved_count":"int","resolution_rate_pct":"num","avg_resolution_days":"num","max_resolution_days":"int","avg_satisfaction_score":"num","low_satisfaction_count":"int"},
        "mart_kpi_monthly": {"month_start":"date","year":"int","quarter":"int","new_customers":"int","new_accounts":"int","loans_disbursed":"int","loan_amount_disbursed":"num","avg_interest_rate":"num","loan_payment_count":"int","loan_collections":"num","interest_income":"num","late_payment_rate_pct":"num","txn_count":"int","txn_amount":"num","transacting_accounts":"int","avg_txn_amount":"num","card_txn_count":"int","card_spend":"num","fraud_txn_count":"int","fraud_amount":"num","fraud_rate_pct":"num","tickets_opened":"int","tickets_resolved":"int","ticket_resolution_rate_pct":"num","avg_resolution_days":"num","avg_satisfaction_score":"num","cumulative_customers":"num","cumulative_accounts":"num","cumulative_loan_amount":"num","txn_amount_mom_pct":"num","card_spend_mom_pct":"num","loan_collections_mom_pct":"num"}
    }'::JSONB;

    v_meta_cols CONSTANT TEXT[] := ARRAY['mart_refreshed_at'];

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_tbl        RECORD;
    v_col        RECORD;
    v_exists     BOOLEAN;
    v_type_name  TEXT;
    v_family     TEXT;
    v_ok         BOOLEAN;
    v_extra      TEXT[];
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('marts', '07_lp_check_schema_contract.sql')
    RETURNING run_id INTO v_run_id;

    FOR v_tbl IN
        SELECT key AS tbl, value AS cols FROM jsonb_each(v_contract)
    LOOP
        SELECT EXISTS (
            SELECT 1
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_tbl.tbl
              AND c.relkind IN ('r', 'p')
        )
        INTO v_exists;

        IF NOT v_exists THEN
            v_violations := v_violations ||
                format('%I.%I: table not found', v_schema, v_tbl.tbl);
            CONTINUE;
        END IF;

        FOR v_col IN
            SELECT key AS col, value #>> '{}' AS family FROM jsonb_each(v_tbl.cols)
        LOOP
            SELECT format_type(a.atttypid, a.atttypmod),
                   CASE
                       WHEN a.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype) THEN 'int'
                       WHEN a.atttypid IN ('numeric'::regtype, 'float4'::regtype, 'float8'::regtype) THEN 'num'
                       WHEN a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype) THEN 'text'
                       WHEN a.atttypid IN ('date'::regtype, 'timestamp'::regtype, 'timestamptz'::regtype) THEN 'date'
                       WHEN a.atttypid = 'bool'::regtype THEN 'bool'
                       ELSE 'other'
                   END
            INTO v_type_name, v_family
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_tbl.tbl
              AND a.attname = v_col.col
              AND a.attnum  > 0
              AND NOT a.attisdropped;

            IF NOT FOUND THEN
                v_violations := v_violations ||
                    format('%I.%I: missing column %I', v_schema, v_tbl.tbl, v_col.col);
                CONTINUE;
            END IF;

            v_checked := v_checked + 1;

            v_ok := v_col.family = v_family
                    OR (v_col.family = 'num'  AND v_family = 'int')
                    OR (v_col.family = 'flag' AND v_family IN ('int', 'num', 'text', 'bool'))
                    OR (v_col.family = 'any');

            IF NOT v_ok THEN
                v_violations := v_violations ||
                    format('%I.%I.%I: type is %s, contract expects %s',
                           v_schema, v_tbl.tbl, v_col.col, v_type_name, v_col.family);
            END IF;
        END LOOP;

        IF v_forbid_extra THEN
            SELECT array_agg(a.attname ORDER BY a.attnum)
            INTO v_extra
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_tbl.tbl
              AND a.attnum  > 0
              AND NOT a.attisdropped
              AND a.attname <> ALL (v_meta_cols)
              AND NOT (v_tbl.cols ? a.attname);

            IF v_extra IS NOT NULL THEN
                v_violations := v_violations ||
                    format('%I.%I: unexpected column(s): %s',
                           v_schema, v_tbl.tbl, array_to_string(v_extra, ', '));
            END IF;
        END IF;
    END LOOP;

    -- ---- 5. every marts table must be in the contract ----
    FOR v_tbl IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND NOT (v_contract ? c.relname)
        ORDER BY c.relname
    LOOP
        v_violations := v_violations ||
            format('%I.%I: table has no contract entry', v_schema, v_tbl.relname);
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
        RAISE EXCEPTION E'Marts schema contract violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All schema contract checks passed: % columns in schema %',
        v_checked, v_schema;
END $$;
