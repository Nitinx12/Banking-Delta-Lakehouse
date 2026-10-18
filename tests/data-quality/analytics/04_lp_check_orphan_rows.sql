-- ============================================================
-- Script Name : 04_lp_check_orphan_rows.sql
-- Purpose     : Validate analytics-schema referential integrity.
--               Fails with a single error that lists all violations.
-- Checks      :
--   1. Every configured fact/dim key resolves to a parent row.
--   2. Child and parent tables/columns exist (config errors are
--      reported, the relationship is skipped).
--   3. Surrogate key and natural key agree (dim_account.customer_key
--      must point at the dim_customer row holding the same
--      customer_id, and so on).
--   4. No fact row is resolved to the Unknown member (*_key = -1).
--   5. No natural key is left unresolved on the Unknown member.
--   6. Every dimension holds exactly one Unknown member (*_key = -1).
-- Note        : This is a PROCEDURE (not a DO block) so it can COMMIT,
--               letting the audit rows survive the final RAISE EXCEPTION.
--               Run with autocommit (psql, pg_cron, or run_analytics_tests.py).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_orphan_rows_check()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'analytics';

    -- [child_table, child_column, parent_table, parent_column]
    v_fks CONSTANT JSONB := '[
        ["dim_account",          "customer_key",     "dim_customer",          "customer_key"],
        ["dim_employee",         "branch_key",        "dim_branch",            "branch_key"],
        ["dim_card",             "account_key",       "dim_account",           "account_key"],
        ["dim_card",             "customer_key",      "dim_customer",          "customer_key"],
        ["dim_loan",             "customer_key",      "dim_customer",          "customer_key"],
        ["dim_loan",             "branch_key",        "dim_branch",            "branch_key"],
        ["fact_card_transactions","card_key",         "dim_card",              "card_key"],
        ["fact_loan_payments",   "loan_key",          "dim_loan",              "loan_key"],
        ["fact_transactions",    "account_key",       "dim_account",           "account_key"],
        ["fact_transactions",    "txn_profile_key",   "dim_txn_profile",       "txn_profile_key"],
        ["fact_support_tickets", "customer_key",      "dim_customer",          "customer_key"]
    ]'::JSONB;

    -- [child, natural_col, key_col, parent, parent_natural_col]
    v_align CONSTANT JSONB := '[
        ["dim_account",      "customer_id", "customer_key", "dim_customer", "customer_id"],
        ["dim_card",         "customer_id", "customer_key", "dim_customer", "customer_id"],
        ["dim_card",         "account_id",  "account_key",  "dim_account",  "account_id"],
        ["dim_loan",         "customer_id", "customer_key", "dim_customer", "customer_id"],
        ["dim_loan",         "branch_id",   "branch_key",   "dim_branch",   "branch_id"],
        ["dim_employee",     "branch_id",   "branch_key",   "dim_branch",   "branch_id"],
        ["fact_support_tickets", "customer_id", "customer_key", "dim_customer", "customer_id"]
    ]'::JSONB;

    -- facts must never resolve to the Unknown member
    v_fact_keys CONSTANT JSONB := '[
        ["fact_card_transactions", "card_key"],
        ["fact_loan_payments",     "loan_key"],
        ["fact_transactions",      "account_key"],
        ["fact_transactions",      "txn_profile_key"],
        ["fact_support_tickets",   "customer_key"]
    ]'::JSONB;

    -- dimensions that must hold exactly one Unknown member
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
    v_violations     TEXT[] := ARRAY[]::TEXT[];
    v_fk             RECORD;
    v_missing_tables TEXT[];
    v_orphans        BIGINT;
    v_examples       TEXT;
    v_checked        INT := 0;
    v_run_id         BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('analytics', '04_lp_check_orphan_rows.sql')
    RETURNING run_id INTO v_run_id;

    -- ---- 1-2. key columns resolve to a parent row ----
    FOR v_fk IN
        SELECT e ->> 0 AS child, e ->> 1 AS ccol,
               e ->> 2 AS parent, e ->> 3 AS pcol
        FROM jsonb_array_elements(v_fks) AS e
    LOOP
        SELECT array_agg(x.tbl ORDER BY x.tbl)
        INTO v_missing_tables
        FROM (VALUES (v_fk.child), (v_fk.parent)) AS x(tbl)
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = x.tbl AND c.relkind IN ('r', 'p')
        );

        IF v_missing_tables IS NOT NULL THEN
            v_violations := v_violations ||
                format('config error: table(s) not found in schema %I: %s',
                       v_schema, array_to_string(v_missing_tables, ', '));
            CONTINUE;
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = v_fk.child
              AND a.attname = v_fk.ccol AND a.attnum > 0 AND NOT a.attisdropped
        ) OR NOT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = v_fk.parent
              AND a.attname = v_fk.pcol AND a.attnum > 0 AND NOT a.attisdropped
        ) THEN
            v_violations := v_violations ||
                format('config error: column(s) not found: %I.%I -> %I.%I',
                       v_fk.child, v_fk.ccol, v_fk.parent, v_fk.pcol);
            CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT count(*),
                   array_to_string((array_agg(c.%1$I::text ORDER BY c.%1$I::text))[1:3], ', ')
            FROM %2$I.%3$I c
            WHERE c.%1$I IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM %2$I.%4$I p WHERE p.%5$I = c.%1$I)
        $q$, v_fk.ccol, v_schema, v_fk.child, v_fk.parent, v_fk.pcol)
        INTO v_orphans, v_examples;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%(%) -> %.%(%): % orphan rows',
            v_schema, v_fk.child, v_fk.ccol, v_schema, v_fk.parent, v_fk.pcol, v_orphans;

        IF v_orphans > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s orphan rows with no match in %I.%I (examples: %s)',
                       v_schema, v_fk.child, v_fk.ccol, v_orphans,
                       v_schema, v_fk.parent, v_fk.pcol, coalesce(v_examples, 'none'));
        END IF;
    END LOOP;

    -- ---- 3-5. surrogate key agrees with the natural key ----
    FOR v_fk IN
        SELECT e ->> 0 AS child, e ->> 1 AS nat_col, e ->> 2 AS key_col,
               e ->> 3 AS parent, e ->> 4 AS p_nat_col
        FROM jsonb_array_elements(v_align) AS e
    LOOP
        EXECUTE format($q$
            SELECT count(*),
                   array_to_string((array_agg(c.%1$I::text ORDER BY c.%1$I::text))[1:3], ', ')
            FROM %2$I.%3$I c
            JOIN %2$I.%4$I p ON p.%5$I = c.%6$I
            WHERE c.%6$I <> -1
              AND c.%1$I IS NOT NULL
              AND p.%7$I IS DISTINCT FROM c.%1$I
        $q$, v_fk.nat_col, v_schema, v_fk.child, v_fk.parent, v_fk.key_col,
             v_fk.key_col, v_fk.p_nat_col)
        INTO v_orphans, v_examples;

        v_checked := v_checked + 1;

        IF v_orphans > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows where %I does not match %I.%I reached via %I (e.g. %s)',
                       v_schema, v_fk.child, v_orphans, v_fk.nat_col,
                       v_schema, v_fk.parent, v_fk.p_nat_col, v_fk.key_col,
                       coalesce(v_examples, 'none'));
        END IF;

        -- natural key present but resolved to the Unknown member
        EXECUTE format(
            'SELECT count(*) FROM %2$I.%3$I WHERE %4$I = -1 AND %1$I IS NOT NULL',
            v_fk.nat_col, v_schema, v_fk.child, v_fk.key_col)
        INTO v_orphans;

        IF v_orphans > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with a real %I resolved to the Unknown member via %I',
                       v_schema, v_fk.child, v_orphans, v_fk.nat_col, v_fk.key_col);
        END IF;
    END LOOP;

    -- ---- 4. facts must not resolve to the Unknown member ----
    FOR v_fk IN
        SELECT e ->> 0 AS tbl, e ->> 1 AS key_col
        FROM jsonb_array_elements(v_fact_keys) AS e
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %I = -1',
                       v_schema, v_fk.tbl, v_fk.key_col)
        INTO v_orphans;

        v_checked := v_checked + 1;

        IF v_orphans > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s fact rows resolved to the Unknown member (-1)',
                       v_schema, v_fk.tbl, v_fk.key_col, v_orphans);
        END IF;
    END LOOP;

    -- ---- 6. exactly one Unknown member per dimension ----
    FOR v_fk IN
        SELECT key AS tbl, value #>> '{}' AS key_col FROM jsonb_each(v_unknown_keys)
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %I = -1',
                       v_schema, v_fk.tbl, v_fk.key_col)
        INTO v_orphans;

        v_checked := v_checked + 1;

        IF v_orphans <> 1 THEN
            v_violations := v_violations ||
                format('%I.%I: %s Unknown members on %I (expected exactly 1)',
                       v_schema, v_fk.tbl, v_orphans, v_fk.key_col);
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
        RAISE EXCEPTION E'Analytics referential integrity violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All referential integrity checks passed: % checks in schema %',
        v_checked, v_schema;
END $$;
