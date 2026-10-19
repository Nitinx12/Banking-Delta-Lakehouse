-- ============================================================
-- Script Name : 04_lp_check_orphan_rows.sql
-- Purpose     : Validate marts referential integrity back to the
--               analytics dimensions they were built from. Fails
--               with a single error that lists all violations.
-- Checks      :
--   1. Every configured mart key resolves to a parent analytics row.
--   2. Child mart key agrees with the natural key of the parent it
--      points at.
--   3. Mart category keys exist as a combination in their dimension
--      (e.g. the monthly transaction profile triple).
--   4. Child / parent tables and columns exist (config errors are
--      reported, the relationship is skipped).
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_orphan_rows_check()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema        CONSTANT TEXT := 'marts';
    v_parent_schema CONSTANT TEXT := 'analytics';

    -- [child, child_column, parent_schema, parent_table, parent_column]
    v_fks CONSTANT JSONB := '[
        ["mart_customer_360",       "customer_key", "analytics", "dim_customer", "customer_key"],
        ["mart_branch_performance", "branch_key",   "analytics", "dim_branch",   "branch_key"]
    ]'::JSONB;

    -- [child, natural_col, key_col, parent_schema, parent, parent_natural_col]
    v_align CONSTANT JSONB := '[
        ["mart_customer_360",       "customer_id", "customer_key", "analytics", "dim_customer", "customer_id"],
        ["mart_branch_performance", "branch_id",   "branch_key",   "analytics", "dim_branch",   "branch_id"]
    ]'::JSONB;

    -- [child, [child cols], parent_schema, parent, [parent cols]]
    v_membership CONSTANT JSONB := '[
        ["mart_monthly_transactions",
         ["txn_type", "channel", "merchant_category", "txn_direction"],
         "analytics", "dim_txn_profile",
         ["txn_type", "channel", "merchant_category", "txn_direction"]]
    ]'::JSONB;

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_fk         RECORD;
    v_orphans    BIGINT;
    v_examples   TEXT;
    v_match      TEXT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('marts', '04_lp_check_orphan_rows.sql')
    RETURNING run_id INTO v_run_id;

    -- ---- 1. mart keys resolve to a parent analytics row ----
    FOR v_fk IN
        SELECT e ->> 0 AS child, e ->> 1 AS ccol,
               e ->> 2 AS pschema, e ->> 3 AS parent, e ->> 4 AS pcol
        FROM jsonb_array_elements(v_fks) AS e
    LOOP
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
            WHERE n.nspname = v_fk.pschema AND c.relname = v_fk.parent
              AND a.attname = v_fk.pcol AND a.attnum > 0 AND NOT a.attisdropped
        ) THEN
            v_violations := v_violations ||
                format('config error: column(s) not found: %I.%I -> %I.%I.%I',
                       v_schema, v_fk.child, v_fk.pschema, v_fk.parent, v_fk.pcol);
            CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT count(*),
                   array_to_string((array_agg(c.%1$I::text ORDER BY c.%1$I::text))[1:3], ', ')
            FROM %2$I.%3$I c
            WHERE c.%1$I IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM %4$I.%5$I p WHERE p.%6$I = c.%1$I)
        $q$, v_fk.ccol, v_schema, v_fk.child, v_fk.pschema, v_fk.parent, v_fk.pcol)
        INTO v_orphans, v_examples;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%(%) -> %.%(%): % orphan rows',
            v_schema, v_fk.child, v_fk.ccol, v_fk.pschema, v_fk.parent,
            v_fk.pcol, v_orphans;

        IF v_orphans > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s orphan rows with no match in %I.%I (examples: %s)',
                       v_schema, v_fk.child, v_fk.ccol, v_orphans,
                       v_fk.pschema, v_fk.parent, coalesce(v_examples, 'none'));
        END IF;
    END LOOP;

    -- ---- 2. surrogate key agrees with the parent natural key ----
    FOR v_fk IN
        SELECT e ->> 0 AS child, e ->> 1 AS nat_col, e ->> 2 AS key_col,
               e ->> 3 AS pschema, e ->> 4 AS parent, e ->> 5 AS p_nat_col
        FROM jsonb_array_elements(v_align) AS e
    LOOP
        EXECUTE format($q$
            SELECT count(*),
                   array_to_string((array_agg(c.%1$I::text ORDER BY c.%1$I::text))[1:3], ', ')
            FROM %2$I.%3$I c
            JOIN %4$I.%5$I p ON p.%6$I = c.%7$I
            WHERE c.%1$I IS NOT NULL
              AND p.%8$I IS DISTINCT FROM c.%1$I
        $q$, v_fk.nat_col, v_schema, v_fk.child, v_fk.pschema, v_fk.parent,
             v_fk.key_col, v_fk.key_col, v_fk.p_nat_col)
        INTO v_orphans, v_examples;

        v_checked := v_checked + 1;

        IF v_orphans > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows where %I does not match %I.%I.%I reached via %I (e.g. %s)',
                       v_schema, v_fk.child, v_orphans, v_fk.nat_col,
                       v_fk.pschema, v_fk.parent, v_fk.p_nat_col, v_fk.key_col,
                       coalesce(v_examples, 'none'));
        END IF;
    END LOOP;

    -- ---- 3. mart category keys exist as a combination in the dimension ----
    FOR v_fk IN
        SELECT e ->> 0 AS child, e -> 1 AS child_cols,
               e ->> 2 AS pschema, e ->> 3 AS parent, e -> 4 AS parent_cols
        FROM jsonb_array_elements(v_membership) AS e
    LOOP
        SELECT string_agg(
                   format('p.%I IS NOT DISTINCT FROM c.%I', x.pc, x.cc),
                   ' AND ' ORDER BY x.ord)
        INTO v_match
        FROM (
            SELECT cc.value AS cc, pc.value AS pc, cc.ord
            FROM jsonb_array_elements_text(v_fk.child_cols)
                 WITH ORDINALITY AS cc(value, ord)
            JOIN jsonb_array_elements_text(v_fk.parent_cols)
                 WITH ORDINALITY AS pc(value, ord) USING (ord)
        ) x;

        EXECUTE format($q$
            SELECT count(*) FROM %1$I.%2$I c
            WHERE NOT EXISTS (
                SELECT 1 FROM %3$I.%4$I p WHERE %5$s
            )
        $q$, v_schema, v_fk.child, v_fk.pschema, v_fk.parent, v_match)
        INTO v_orphans;

        v_checked := v_checked + 1;

        IF v_orphans > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows whose category combination is missing from %I.%I',
                       v_schema, v_fk.child, v_orphans, v_fk.pschema, v_fk.parent);
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
        RAISE EXCEPTION E'Marts referential integrity violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All referential integrity checks passed: % checks in schema %',
        v_checked, v_schema;
END $$;
