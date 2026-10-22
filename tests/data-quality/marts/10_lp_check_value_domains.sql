-- ============================================================
-- Script Name : 10_lp_check_value_domains.sql
-- Purpose     : Fail on categorical values outside their allowed
--               set, and on untrimmed, empty or placeholder text in
--               the marts schema. One error lists all violations.
-- Checks      : 1. Categorical columns only hold allowed values
--               2. No leading/trailing whitespace in any text column
--               3. No empty or placeholder strings in any text column
-- Note        : the allowed sets mirror the analytics domains the
--               marts inherit; a subset of the allowed values is
--               fine (a band with no rows this refresh)
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_value_domains(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'marts';

    v_domains CONSTANT JSONB := '{
        "mart_customer_360.gender":                 ["Female", "Male", "N/A"],
        "mart_customer_360.age_band":               ["18-24", "25-34", "35-44", "45-54", "55-64", "65+", "Unknown"],
        "mart_customer_360.income_band":            ["Low (<3L)", "Lower-Mid (3-6L)", "Middle (6-12L)", "Upper-Mid (12-24L)", "High (24L+)", "Unknown"],
        "mart_customer_360.credit_band":            ["Poor", "Fair", "Good", "Excellent", "Unknown"],
        "mart_customer_360.occupation":             ["Business Owner", "Freelancer", "Retired", "Salaried - Government", "Salaried - Private", "Self Employed", "Student"],
        "mart_branch_performance.region":           ["North", "South", "East", "West", "Central", "Northeast", "Other", "Unknown"],
        "mart_branch_performance.branch_age_band":  ["<2 yrs", "2-5 yrs", "5-10 yrs", "10+ yrs", "Unknown"],
        "mart_monthly_transactions.txn_direction":  ["Inflow", "Outflow", "Unknown"],
        "mart_loan_portfolio.loan_type":            ["Auto Loan", "Business Loan", "Education Loan", "Gold Loan", "Home Loan", "Personal Loan", "Unknown"],
        "mart_loan_portfolio.status":               ["Active", "Closed", "Defaulted", "Written Off", "Unknown"],
        "mart_loan_portfolio.loan_amount_band":     ["<1L", "1-5L", "5-25L", "25L-1Cr", "1Cr+", "Unknown"],
        "mart_loan_portfolio.term_band":            ["<=1 yr", "1-5 yrs", "5-15 yrs", "15+ yrs", "Unknown"],
        "mart_card_fraud.card_type":                ["Credit - Classic", "Credit - Gold", "Credit - Platinum", "Debit", "Unknown"],
        "mart_card_fraud.card_category":            ["Credit", "Debit", "Unknown"],
        "mart_card_fraud.card_tier":                ["N/A", "Classic", "Gold", "Platinum", "Unknown"],
        "mart_support_performance.issue_type":      ["Account Statement", "App Login Issue", "Card Blocked", "Cheque Bounce", "Fraud Report", "Interest Query", "KYC Update", "Loan Query", "Net Banking Issue", "Wrong Debit"],
        "mart_support_performance.status":          ["Escalated", "Open", "Resolved"],
        "mart_support_performance.income_band":     ["Low (<3L)", "Lower-Mid (3-6L)", "Middle (6-12L)", "Upper-Mid (12-24L)", "High (24L+)", "Unknown"]
    }'::JSONB;

    v_placeholders CONSTANT TEXT[] := ARRAY['NA', 'NULL', 'null', 'None', 'n/a', '-']::TEXT[];

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_tbl        RECORD;
    v_rule       RECORD;
    v_vals       TEXT[];
    v_bad        BIGINT;
    v_examples   TEXT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('marts', '10_lp_check_value_domains.sql', p_pipeline_run_id)
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

    -- ---- 2-3. whitespace and placeholders in every text column ----
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
        EXECUTE format(
            'SELECT count(*) FROM %I.%I WHERE %I IS NOT NULL AND %I::text <> btrim(%I::text)',
            v_schema, v_tbl.relname, v_tbl.attname, v_tbl.attname, v_tbl.attname)
        INTO v_bad;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s values with leading/trailing whitespace',
                       v_schema, v_tbl.relname, v_tbl.attname, v_bad);
        END IF;

        EXECUTE format(
            'SELECT count(*) FROM %1$I.%2$I
             WHERE btrim(%3$I::text) = '''' OR btrim(%3$I::text) = ANY (%4$L::text[])',
            v_schema, v_tbl.relname, v_tbl.attname, v_placeholders)
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
        RAISE EXCEPTION E'Marts value domain violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All value domain checks passed: % rules in schema %',
        v_checked, v_schema;
END $$;
