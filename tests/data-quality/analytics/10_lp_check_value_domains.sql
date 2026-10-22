-- ============================================================
-- Script Name : 10_lp_check_value_domains.sql
-- Purpose     : Fail on categorical values outside their allowed
--               set, malformed formatted values, and untrimmed or
--               placeholder text in the analytics schema. One error
--               lists all violations.
-- Checks      : 1. Categorical columns only hold allowed values
--               2. Formatted columns match their regex
--               3. No leading/trailing whitespace in any text column
--               4. No empty or placeholder strings in any text column
-- Note        : 'Unknown' / 'N/A' are legitimate analytics defaults
--               for derived bands and are therefore not placeholders;
--               their correctness is enforced by
--               12_lp_check_derived_attributes.sql
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_value_domains(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'analytics';

    v_domains CONSTANT JSONB := '{
        "dim_customer.gender":                 ["Female", "Male", "N/A"],
        "dim_customer.age_band":               ["18-24", "25-34", "35-44", "45-54", "55-64", "65+", "Unknown"],
        "dim_customer.income_band":            ["Low (<3L)", "Lower-Mid (3-6L)", "Middle (6-12L)", "Upper-Mid (12-24L)", "High (24L+)", "Unknown"],
        "dim_customer.credit_band":            ["Poor", "Fair", "Good", "Excellent", "Unknown"],
        "dim_customer.occupation":             ["Business Owner", "Freelancer", "Retired", "Salaried - Government", "Salaried - Private", "Self Employed", "Student"],
        "dim_account.account_type":            ["Current", "Fixed Deposit", "NRI", "Salary", "Savings", "Unknown"],
        "dim_account.status":                  ["Active", "Closed", "Dormant", "Unknown"],
        "dim_account.account_age_band":        ["<1 yr", "1-3 yrs", "3-5 yrs", "5+ yrs", "Unknown"],
        "dim_branch.region":                   ["North", "South", "East", "West", "Central", "Northeast", "Other", "Unknown"],
        "dim_branch.branch_age_band":          ["<2 yrs", "2-5 yrs", "5-10 yrs", "10+ yrs", "Unknown"],
        "dim_employee.role":                   ["Branch Manager", "Compliance Officer", "Customer Service", "Loan Officer", "Relationship Manager", "Teller", "Unknown"],
        "dim_employee.tenure_band":            ["<1 yr", "1-3 yrs", "3-5 yrs", "5-10 yrs", "10+ yrs", "Unknown"],
        "dim_card.card_type":                  ["Credit - Classic", "Credit - Gold", "Credit - Platinum", "Debit", "Unknown"],
        "dim_card.card_category":              ["Credit", "Debit", "Unknown"],
        "dim_card.card_tier":                  ["N/A", "Classic", "Gold", "Platinum", "Unknown"],
        "dim_card.status":                     ["Active", "Blocked", "Expired", "Unknown"],
        "dim_loan.loan_type":                  ["Auto Loan", "Business Loan", "Education Loan", "Gold Loan", "Home Loan", "Personal Loan", "Unknown"],
        "dim_loan.status":                     ["Active", "Closed", "Defaulted", "Written Off", "Unknown"],
        "dim_loan.loan_amount_band":           ["<1L", "1-5L", "5-25L", "25L-1Cr", "1Cr+", "Unknown"],
        "dim_loan.term_band":                  ["<=1 yr", "1-5 yrs", "5-15 yrs", "15+ yrs", "Unknown"],
        "dim_txn_profile.txn_direction":       ["Inflow", "Outflow", "Unknown"],
        "fact_support_tickets.status":         ["Escalated", "Open", "Resolved"],
        "fact_support_tickets.issue_type":     ["Account Statement", "App Login Issue", "Card Blocked", "Cheque Bounce", "Fraud Report", "Interest Query", "KYC Update", "Loan Query", "Net Banking Issue", "Wrong Debit"],
        "fact_loan_payments.amount_check":     ["DERIVED", "INCOMPLETE", "MISMATCH", "OK"]
    }'::JSONB;

    -- staging cleaning guarantees kept by the analytics loads
    v_formats CONSTANT JSONB := '{
        "dim_customer.phone":    "^[6-9][0-9]{9}$",
        "dim_customer.email":    "^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$",
        "dim_branch.ifsc_code":  "^[A-Z]{3}[0-9]{7}$"
    }'::JSONB;

    v_placeholders CONSTANT TEXT[] := ARRAY['NA', 'NULL', 'null', 'None', 'n/a', '-']::TEXT[];

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
    v_tbl        RECORD;
    v_rule       RECORD;
    v_vals       TEXT[];
    v_bad        BIGINT;
    v_examples   TEXT;
    v_filter     TEXT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('analytics', '10_lp_check_value_domains.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    -- ---- 1. categorical domains ----
    FOR v_rule IN
        SELECT key, value FROM jsonb_each(v_domains)
    LOOP
        DECLARE
            v_tbl_name TEXT := split_part(v_rule.key, '.', 1);
            v_col_name TEXT := split_part(v_rule.key, '.', 2);
        BEGIN
            SELECT array_agg(x) INTO v_vals
            FROM jsonb_array_elements_text(v_rule.value) AS x;

            EXECUTE format($q$
                SELECT count(*),
                       array_to_string((array_agg(DISTINCT %1$I::text))[1:5], ', ')
                FROM %2$I.%3$I
                WHERE %1$I IS NOT NULL AND %1$I::text <> ALL (%4$L::text[])
            $q$, v_col_name, v_schema, v_tbl_name, v_vals)
            INTO v_bad, v_examples;

            v_checked := v_checked + 1;
            RAISE NOTICE '%: domain check', v_rule.key;

            IF v_bad > 0 THEN
                v_violations := v_violations ||
                    format('%s: %s values outside the allowed set (e.g. %s)',
                           v_rule.key, v_bad, v_examples);
            END IF;
        END;
    END LOOP;

    -- ---- 2. format patterns ----
    FOR v_rule IN
        SELECT key, value #>> '{}' AS pattern FROM jsonb_each(v_formats)
    LOOP
        DECLARE
            v_tbl_name TEXT := split_part(v_rule.key, '.', 1);
            v_col_name TEXT := split_part(v_rule.key, '.', 2);
        BEGIN
            EXECUTE format($q$
                SELECT count(*),
                       array_to_string((array_agg(DISTINCT %1$I::text))[1:3], ', ')
                FROM %2$I.%3$I
                WHERE %1$I IS NOT NULL AND %1$I::text !~ %4$L
            $q$, v_col_name, v_schema, v_tbl_name, v_rule.pattern)
            INTO v_bad, v_examples;

            v_checked := v_checked + 1;
            RAISE NOTICE '%: format check', v_rule.key;

            IF v_bad > 0 THEN
                v_violations := v_violations ||
                    format('%s: %s values do not match %s (e.g. %s)',
                           v_rule.key, v_bad, v_rule.pattern, v_examples);
            END IF;
        END;
    END LOOP;

    -- ---- 3-4. whitespace and placeholders in every text column ----
    FOR v_tbl IN
        SELECT c.relname, a.attname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid
                           AND a.attnum > 0
                           AND NOT a.attisdropped
                           AND a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
        ORDER BY c.relname, a.attnum
    LOOP
        v_filter := CASE WHEN v_unknown_keys ? v_tbl.relname
                         THEN format('%I <> -1', v_unknown_keys ->> v_tbl.relname)
                         ELSE 'TRUE' END;

        EXECUTE format(
            'SELECT count(*) FROM %I.%I WHERE %s AND %I::text <> btrim(%I::text)',
            v_schema, v_tbl.relname, v_filter, v_tbl.attname, v_tbl.attname)
        INTO v_bad;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s values with leading/trailing whitespace',
                       v_schema, v_tbl.relname, v_tbl.attname, v_bad);
        END IF;

        EXECUTE format(
            'SELECT count(*) FROM %1$I.%2$I
             WHERE %5$s AND (btrim(%3$I::text) = '''' OR btrim(%3$I::text) = ANY (%4$L::text[]))',
            v_schema, v_tbl.relname, v_tbl.attname, v_placeholders, v_filter)
        INTO v_bad;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s empty/placeholder values',
                       v_schema, v_tbl.relname, v_tbl.attname, v_bad);
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
        RAISE EXCEPTION E'Analytics value domain violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All value domain checks passed: % rules in schema %',
        v_checked, v_schema;
END $$;
