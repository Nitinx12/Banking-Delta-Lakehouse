-- ============================================================
-- Script Name : 04_lp_check_orphan_rows.sql
-- Purpose     : Validate staging-schema referential integrity.
-- Checks      :
--   1. Child and parent tables exist.
--   2. Child and parent columns exist.
--   3. Type-category mismatches are reported.
--   4. Orphan values are counted and example values reported.
--   5. NULL child values are ignored.
-- Behavior    :
--   - Type mismatches use trimmed text comparison for diagnostics.
--   - All violations are collected before raising an exception.
--   - Missing tables or columns are reported and skipped.
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_staging_orphan_rows_check(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- Configuration ----------
    v_schema CONSTANT TEXT := 'staging';

    -- [child_table, child_column, parent_table, parent_column]
    v_fks CONSTANT JSONB := '[
        ["accounts",          "customer_id", "customers", "customer_id"],
        ["accounts",          "branch_id",   "branches",  "branch_id"],
        ["cards",             "customer_id", "customers", "customer_id"],
        ["cards",             "account_id",  "accounts",  "account_id"],
        ["employees",         "branch_id",   "branches",  "branch_id"],
        ["loans",             "customer_id", "customers", "customer_id"],
        ["loans",             "branch_id",   "branches",  "branch_id"],
        ["loan_payments",     "loan_id",     "loans",     "loan_id"],
        ["support_tickets",   "customer_id", "customers", "customer_id"],
        ["transactions",      "account_id",  "accounts",  "account_id"],
        ["card_transactions", "card_id",     "cards",     "card_id"]
    ]'::JSONB;

    -- ---------- Working variables ----------
    v_violations     TEXT[] := ARRAY[]::TEXT[];
    v_fk             RECORD;
    v_missing_tables TEXT[];
    v_missing_cols   TEXT[];

    v_ccat           "char";
    v_pcat           "char";
    v_ctype          TEXT;
    v_ptype          TEXT;
    v_join_cond      TEXT;
    v_run_id         BIGINT;

    v_orphans        BIGINT;
    v_examples       TEXT;
    v_checked        INT := 0;
    v_t0             TIMESTAMPTZ;

BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('staging', '04_lp_check_orphan_rows.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    -- Iterate through the configured relationships.
    FOR v_fk IN
        SELECT
            e.value ->> 0 AS child,
            e.value ->> 1 AS ccol,
            e.value ->> 2 AS parent,
            e.value ->> 3 AS pcol
        FROM jsonb_array_elements(v_fks) AS e(value)
    LOOP

        -- Validate that the configured relationship is complete.
        IF NULLIF(BTRIM(v_fk.child), '') IS NULL
           OR NULLIF(BTRIM(v_fk.ccol), '') IS NULL
           OR NULLIF(BTRIM(v_fk.parent), '') IS NULL
           OR NULLIF(BTRIM(v_fk.pcol), '') IS NULL
        THEN
            v_violations := v_violations ||
                FORMAT(
                    'config error: incomplete relationship configuration: %s',
                    v_fk
                );

            CONTINUE;
        END IF;

        -- ----------------------------------------------------
        -- 1. Validate that both tables exist.
        -- ----------------------------------------------------
        SELECT ARRAY_AGG(x.tbl ORDER BY x.tbl)
        INTO v_missing_tables
        FROM (
            SELECT DISTINCT required.tbl
            FROM (
                VALUES
                    (v_fk.child),
                    (v_fk.parent)
            ) AS required(tbl)
        ) AS x
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_class AS c
            JOIN pg_namespace AS n
              ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = x.tbl
              AND c.relkind IN ('r', 'p', 'f')
        );

        IF v_missing_tables IS NOT NULL THEN
            v_violations := v_violations ||
                FORMAT(
                    'config error: table(s) not found in schema %I: %s',
                    v_schema,
                    ARRAY_TO_STRING(v_missing_tables, ', ')
                );

            CONTINUE;
        END IF;

        -- ----------------------------------------------------
        -- 2. Validate that both columns exist.
        -- ----------------------------------------------------
        SELECT ARRAY_AGG(
                   FORMAT('%I.%I', x.tbl, x.col)
                   ORDER BY x.tbl, x.col
               )
        INTO v_missing_cols
        FROM (
            VALUES
                (v_fk.child,  v_fk.ccol),
                (v_fk.parent, v_fk.pcol)
        ) AS x(tbl, col)
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_attribute AS a
            JOIN pg_class AS c
              ON c.oid = a.attrelid
            JOIN pg_namespace AS n
              ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = x.tbl
              AND c.relkind IN ('r', 'p', 'f')
              AND a.attname = x.col
              AND a.attnum > 0
              AND NOT a.attisdropped
        );

        IF v_missing_cols IS NOT NULL THEN
            v_violations := v_violations ||
                FORMAT(
                    'config error: column(s) not found: %s',
                    ARRAY_TO_STRING(v_missing_cols, ', ')
                );

            CONTINUE;
        END IF;

        -- ----------------------------------------------------
        -- 3. Check type-category compatibility.
        -- Domain types use their underlying base type category.
        -- ----------------------------------------------------
        SELECT
            COALESCE(cbt.typcategory, ct.typcategory),
            COALESCE(pbt.typcategory, pt.typcategory),
            FORMAT_TYPE(ca.atttypid, ca.atttypmod),
            FORMAT_TYPE(pa.atttypid, pa.atttypmod)
        INTO
            v_ccat,
            v_pcat,
            v_ctype,
            v_ptype
        FROM pg_namespace AS n
        JOIN pg_class AS cc
          ON cc.relnamespace = n.oid
         AND cc.relname = v_fk.child
        JOIN pg_attribute AS ca
          ON ca.attrelid = cc.oid
         AND ca.attname = v_fk.ccol
         AND ca.attnum > 0
         AND NOT ca.attisdropped
        JOIN pg_type AS ct
          ON ct.oid = ca.atttypid
        LEFT JOIN pg_type AS cbt
          ON ct.typtype = 'd'
         AND cbt.oid = ct.typbasetype
        JOIN pg_class AS pc
          ON pc.relnamespace = n.oid
         AND pc.relname = v_fk.parent
        JOIN pg_attribute AS pa
          ON pa.attrelid = pc.oid
         AND pa.attname = v_fk.pcol
         AND pa.attnum > 0
         AND NOT pa.attisdropped
        JOIN pg_type AS pt
          ON pt.oid = pa.atttypid
        LEFT JOIN pg_type AS pbt
          ON pt.typtype = 'd'
         AND pbt.oid = pt.typbasetype
        WHERE n.nspname = v_schema;

        -- Keep the existing behavior: report the mismatch,
        -- then run the orphan check using trimmed text.
        IF v_ccat IS DISTINCT FROM v_pcat THEN
            v_violations := v_violations ||
                FORMAT(
                    '%I.%I.%I: type-category mismatch, child is %s but parent %I.%I is %s',
                    v_schema,
                    v_fk.child,
                    v_fk.ccol,
                    v_ctype,
                    v_fk.parent,
                    v_fk.pcol,
                    v_ptype
                );

            v_join_cond := FORMAT(
                'BTRIM(p.%I::TEXT) = BTRIM(c.%I::TEXT)',
                v_fk.pcol,
                v_fk.ccol
            );
        ELSE
            v_join_cond := FORMAT(
                'p.%I = c.%I',
                v_fk.pcol,
                v_fk.ccol
            );
        END IF;

        v_t0 := CLOCK_TIMESTAMP();

        -- ----------------------------------------------------
        -- 4. Count orphan rows and retrieve deterministic
        --    example values.
        -- ----------------------------------------------------
        EXECUTE FORMAT(
            $query$
                WITH orphan_rows AS (
                    SELECT c.%1$I::TEXT AS orphan_value
                    FROM %2$I.%3$I AS c
                    WHERE c.%1$I IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1
                          FROM %2$I.%4$I AS p
                          WHERE %5$s
                      )
                )
                SELECT
                    COUNT(*)::BIGINT,
                    (
                        SELECT STRING_AGG(
                                   sample_value,
                                   ', ' ORDER BY sample_value
                               )
                        FROM (
                            SELECT DISTINCT orphan_value AS sample_value
                            FROM orphan_rows
                            ORDER BY orphan_value
                            LIMIT 3
                        ) AS examples
                    )
                FROM orphan_rows
            $query$,
            v_fk.ccol,
            v_schema,
            v_fk.child,
            v_fk.parent,
            v_join_cond
        )
        INTO v_orphans, v_examples;

        v_checked := v_checked + 1;

        RAISE NOTICE
            '%I.%I(%I) -> %I.%I(%I): % orphan rows [duration: %]',
            v_schema,
            v_fk.child,
            v_fk.ccol,
            v_schema,
            v_fk.parent,
            v_fk.pcol,
            v_orphans,
            CLOCK_TIMESTAMP() - v_t0;

        -- Record orphan violations without stopping other checks.
        IF v_orphans > 0 THEN
            v_violations := v_violations ||
                FORMAT(
                    '%I.%I.%I: %s orphan rows with no match in %I.%I (examples: %s)',
                    v_schema,
                    v_fk.child,
                    v_fk.ccol,
                    v_orphans,
                    v_schema,
                    v_fk.parent,
                    v_fk.pcol,
                    COALESCE(v_examples, 'none')
                );
        END IF;

    END LOOP;

    -- --------------------------------------------------------
    -- 5. Record audit results, then fail after all relationships checked.
    -- --------------------------------------------------------
    INSERT INTO audit.dq_violation (run_id, message)
    SELECT v_run_id, unnest(v_violations);

    UPDATE audit.dq_run
    SET finished_at     = now(),
        violation_count = cardinality(v_violations),
        status          = CASE WHEN cardinality(v_violations) = 0
                               THEN 'PASS' ELSE 'FAIL' END
    WHERE run_id = v_run_id;

    COMMIT;

    IF CARDINALITY(v_violations) > 0 THEN
        RAISE EXCEPTION E'Staging referential integrity violations (%):\n%',
            CARDINALITY(v_violations),
            ARRAY_TO_STRING(v_violations, E'\n');
    END IF;

    RAISE NOTICE
        'All referential integrity checks passed: % relationships in schema %',
        v_checked,
        v_schema;

END;
$$;
