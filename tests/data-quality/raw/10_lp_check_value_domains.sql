-- ============================================================
-- Script Name : 10_lp_check_value_domains.sql
-- Purpose     : Fail on categorical values outside their allowed
--               set, malformed formatted values, and untrimmed or
--               placeholder text. One error lists all violations.
-- Checks      : 1. Categorical columns only hold allowed values
--               2. Formatted columns match their regex
--               3. No leading/trailing whitespace in any text column
--               4. No empty or placeholder strings in any text column
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_raw_value_domains()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'raw';

    v_domains CONSTANT JSONB := '{
        "accounts.account_type":            ["Current", "Fixed Deposit", "NRI", "Salary", "Savings"],
        "accounts.status":                  ["Active", "Closed", "Dormant"],
        "cards.card_type":                  ["Credit - Classic", "Credit - Gold", "Credit - Platinum", "Debit"],
        "cards.status":                     ["Active", "Blocked", "Expired"],
        "customers.gender":                 ["Female", "Male", "Other"],
        "customers.occupation":             ["Business Owner", "Freelancer", "Retired", "Salaried - Government", "Salaried - Private", "Self Employed", "Student"],
        "employees.role":                   ["Branch Manager", "Compliance Officer", "Customer Service", "Loan Officer", "Relationship Manager", "Teller"],
        "branches.state":                   ["Delhi", "Gujarat", "Karnataka", "Kerala", "Madhya Pradesh", "Maharashtra", "Punjab", "Rajasthan", "Tamil Nadu", "Telangana", "Uttar Pradesh", "West Bengal"],
        "loans.loan_type":                  ["Auto Loan", "Business Loan", "Education Loan", "Gold Loan", "Home Loan", "Personal Loan"],
        "loans.status":                     ["Active", "Closed", "Defaulted", "Written Off"],
        "transactions.txn_type":            ["Deposit", "Fee Debit", "Interest Credit", "Transfer In", "Transfer Out", "Withdrawal"],
        "transactions.channel":             ["ATM", "Branch", "Mobile App", "Online Banking", "POS", "UPI"],
        "support_tickets.issue_type":       ["Account Statement", "App Login Issue", "Card Blocked", "Cheque Bounce", "Fraud Report", "Interest Query", "KYC Update", "Loan Query", "Net Banking Issue", "Wrong Debit"],
        "support_tickets.status":           ["Escalated", "Open", "Resolved"],
        "card_transactions.is_fraud":       ["0", "1"],
        "loan_payments.late_payment_flag":  ["0", "1"]
    }'::JSONB;

    v_formats CONSTANT JSONB := '{
        "customers.phone":  "^[0-9]{10}$",
        "customers.email":  "^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$",
        "branches.ifsc_code": "^[A-Z]{3}[0-9]{7}$"
    }'::JSONB;

    v_placeholders CONSTANT TEXT[] := ARRAY['N/A', 'NA', 'NULL', 'null', 'None', 'n/a', '-', 'unknown', 'Unknown'];

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
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('raw', '10_lp_check_value_domains.sql')
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
          AND c.relname NOT LIKE '\_stg\_%'  -- transient staging tables are not raw data
        ORDER BY c.relname, a.attnum
    LOOP
        EXECUTE format(
            'SELECT count(*) FROM %I.%I WHERE %I::text <> btrim(%I::text)',
            v_schema, v_tbl.relname, v_tbl.attname, v_tbl.attname)
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
        RAISE EXCEPTION E'Raw value domain violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All value domain checks passed: % rules in schema %',
        v_checked, v_schema;
END $$;
