-- ============================================================
-- Script Name : 12_lp_check_derived_attributes.sql
-- Purpose     : Recompute every derived analytics attribute and fail
--               when the stored value drifted from its source column.
--               One error lists all violations.
-- Checks      : 1. Derived bands match their source column
--                  (age, income, credit, tenure, age bands, amount
--                  and term bands)
--               2. Derived roll-ups match their source column
--                  (region from state, card_category/card_tier from
--                   card_type, txn_direction from txn_type)
--               3. Extracted year columns match the date column
--               4. dim_loan.maturity_date = start_date + term_months
-- Note        : age / tenure bands are recomputed against
--               CURRENT_DATE, exactly like the load procedures, so a
--               table loaded earlier and never refreshed fails here
--               (that is the drift we want to see)
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_derived_attributes()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'analytics';

    -- "table.column" -> expression over the same row
    v_exprs CONSTANT JSONB := '{
        "dim_customer.age_band": "CASE WHEN date_of_birth IS NULL THEN ''Unknown'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, date_of_birth)) < 25 THEN ''18-24'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, date_of_birth)) < 35 THEN ''25-34'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, date_of_birth)) < 45 THEN ''35-44'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, date_of_birth)) < 55 THEN ''45-54'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, date_of_birth)) < 65 THEN ''55-64'' ELSE ''65+'' END",
        "dim_customer.income_band": "CASE WHEN annual_income IS NULL THEN ''Unknown'' WHEN annual_income < 300000 THEN ''Low (<3L)'' WHEN annual_income < 600000 THEN ''Lower-Mid (3-6L)'' WHEN annual_income < 1200000 THEN ''Middle (6-12L)'' WHEN annual_income < 2400000 THEN ''Upper-Mid (12-24L)'' ELSE ''High (24L+)'' END",
        "dim_customer.credit_band": "CASE WHEN credit_score IS NULL THEN ''Unknown'' WHEN credit_score < 550 THEN ''Poor'' WHEN credit_score < 650 THEN ''Fair'' WHEN credit_score < 750 THEN ''Good'' ELSE ''Excellent'' END",
        "dim_account.account_age_band": "CASE WHEN open_date IS NULL THEN ''Unknown'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, open_date)) < 1 THEN ''<1 yr'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, open_date)) < 3 THEN ''1-3 yrs'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, open_date)) < 5 THEN ''3-5 yrs'' ELSE ''5+ yrs'' END",
        "dim_account.open_year": "EXTRACT(YEAR FROM open_date)::int",
        "dim_branch.branch_age_band": "CASE WHEN opened_date IS NULL THEN ''Unknown'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, opened_date)) < 2 THEN ''<2 yrs'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, opened_date)) < 5 THEN ''2-5 yrs'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, opened_date)) < 10 THEN ''5-10 yrs'' ELSE ''10+ yrs'' END",
        "dim_branch.opened_year": "EXTRACT(YEAR FROM opened_date)::int",
        "dim_branch.region": "CASE WHEN state IS NULL THEN ''Unknown'' WHEN LOWER(state) IN (''delhi'', ''haryana'', ''punjab'', ''himachal pradesh'', ''uttarakhand'', ''uttar pradesh'', ''jammu and kashmir'', ''chandigarh'', ''ladakh'', ''rajasthan'') THEN ''North'' WHEN LOWER(state) IN (''karnataka'', ''tamil nadu'', ''kerala'', ''andhra pradesh'', ''telangana'', ''puducherry'') THEN ''South'' WHEN LOWER(state) IN (''west bengal'', ''odisha'', ''bihar'', ''jharkhand'') THEN ''East'' WHEN LOWER(state) IN (''maharashtra'', ''gujarat'', ''goa'') THEN ''West'' WHEN LOWER(state) IN (''madhya pradesh'', ''chhattisgarh'') THEN ''Central'' WHEN LOWER(state) IN (''assam'', ''meghalaya'', ''manipur'', ''mizoram'', ''nagaland'', ''tripura'', ''arunachal pradesh'', ''sikkim'') THEN ''Northeast'' ELSE ''Other'' END",
        "dim_employee.tenure_band": "CASE WHEN hire_date IS NULL THEN ''Unknown'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, hire_date)) < 1 THEN ''<1 yr'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, hire_date)) < 3 THEN ''1-3 yrs'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, hire_date)) < 5 THEN ''3-5 yrs'' WHEN DATE_PART(''year'', AGE(CURRENT_DATE, hire_date)) < 10 THEN ''5-10 yrs'' ELSE ''10+ yrs'' END",
        "dim_employee.hire_year": "EXTRACT(YEAR FROM hire_date)::int",
        "dim_card.card_category": "CASE WHEN card_type = ''Debit'' THEN ''Debit'' WHEN card_type LIKE ''Credit - %'' THEN ''Credit'' ELSE ''Unknown'' END",
        "dim_card.card_tier": "CASE WHEN card_type = ''Debit'' THEN ''N/A'' WHEN card_type LIKE ''Credit - %'' THEN SPLIT_PART(card_type, '' - '', 2) ELSE ''Unknown'' END",
        "dim_card.issue_year": "EXTRACT(YEAR FROM issue_date)::int",
        "dim_loan.loan_amount_band": "CASE WHEN loan_amount IS NULL THEN ''Unknown'' WHEN loan_amount < 100000 THEN ''<1L'' WHEN loan_amount < 500000 THEN ''1-5L'' WHEN loan_amount < 2500000 THEN ''5-25L'' WHEN loan_amount < 10000000 THEN ''25L-1Cr'' ELSE ''1Cr+'' END",
        "dim_loan.term_band": "CASE WHEN term_months IS NULL THEN ''Unknown'' WHEN term_months <= 12 THEN ''<=1 yr'' WHEN term_months <= 60 THEN ''1-5 yrs'' WHEN term_months <= 180 THEN ''5-15 yrs'' ELSE ''15+ yrs'' END",
        "dim_loan.start_year": "EXTRACT(YEAR FROM start_date)::int",
        "dim_loan.maturity_date": "CASE WHEN start_date IS NOT NULL AND term_months IS NOT NULL THEN (start_date + make_interval(months => term_months))::date END",
        "dim_txn_profile.txn_direction": "CASE WHEN txn_type IN (''Deposit'', ''Transfer In'', ''Interest Credit'') THEN ''Inflow'' WHEN txn_type IN (''Withdrawal'', ''Transfer Out'', ''Fee Debit'') THEN ''Outflow'' ELSE ''Unknown'' END"
    }'::JSONB;

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_rule       RECORD;
    v_tbl_name   TEXT;
    v_col_name   TEXT;
    v_bad        BIGINT;
    v_examples   TEXT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('analytics', '12_lp_check_derived_attributes.sql')
    RETURNING run_id INTO v_run_id;

    FOR v_rule IN
        SELECT key, value #>> '{}' AS expr FROM jsonb_each(v_exprs)
    LOOP
        v_tbl_name := split_part(v_rule.key, '.', 1);
        v_col_name := split_part(v_rule.key, '.', 2);

        IF NOT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = v_tbl_name
              AND a.attname = v_col_name AND a.attnum > 0 AND NOT a.attisdropped
        ) THEN
            v_violations := v_violations ||
                format('config error: %s not found', v_rule.key);
            CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT count(*),
                   array_to_string((array_agg(DISTINCT %1$I::text))[1:3], ', ')
            FROM %2$I.%3$I
            WHERE %1$I IS DISTINCT FROM (%4$s)
        $q$, v_col_name, v_schema, v_tbl_name, v_rule.expr)
        INTO v_bad, v_examples;

        v_checked := v_checked + 1;
        RAISE NOTICE '%: derived attribute check', v_rule.key;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%s: %s rows where the stored value disagrees with its source (e.g. %s)',
                       v_rule.key, v_bad, coalesce(v_examples, 'none'));
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
        RAISE EXCEPTION E'Analytics derived attribute violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All derived attribute checks passed: % columns in schema %',
        v_checked, v_schema;
END $$;
