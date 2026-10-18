-- ============================================================
-- Script Name : 02_lp_check_primary_keys.sql
-- Purpose     : Validate primary keys and business keys on every
--               table in the analytics schema. Fails with a single
--               error that lists all violations.
-- Key lookup  : 1. Declared primary key constraint (every table)
--               2. v_natural_keys (natural / business key that must
--                  also be unique)
-- Checks      : 1. Declared PK exists for every table
--               2. Declared PK index is valid
--               3. No NULL values in any PK column
--               4. No blank strings in text PK columns
--               5. No duplicate PK values
--               6. No NULL / duplicate natural keys
-- Note        : This is a PROCEDURE (not a DO block) so it can COMMIT,
--               letting the audit rows survive the final RAISE EXCEPTION.
--               Run with autocommit (psql, pg_cron, or run_analytics_tests.py).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_primary_key_check()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema        CONSTANT TEXT := 'analytics';
    v_exempt_tables CONSTANT TEXT[] := ARRAY[]::TEXT[];

    -- natural / business keys that must be unique in addition to the PK
    v_natural_keys CONSTANT JSONB := '{
        "dim_customer":    ["customer_id"],
        "dim_account":     ["account_id"],
        "dim_branch":      ["branch_id"],
        "dim_employee":    ["employee_id"],
        "dim_card":        ["card_id"],
        "dim_loan":        ["loan_id"],
        "dim_txn_profile": ["txn_type", "channel", "merchant_category"]
    }'::JSONB;

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_run_id     BIGINT;
    v_tbl        RECORD;
    v_keys       TEXT[];
    v_pk_valid   BOOLEAN;
    v_col_list   TEXT;
    v_null_cond  TEXT;
    v_blank_cond TEXT;
    v_null_rows  BIGINT;
    v_blank_rows BIGINT;
    v_dup_keys   BIGINT;
    v_dup_rows   BIGINT;
    v_checked    INT := 0;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('analytics', '02_lp_check_primary_keys.sql')
    RETURNING run_id INTO v_run_id;

    FOR v_tbl IN
        SELECT c.oid, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname <> ALL (v_exempt_tables)
        ORDER BY c.relname
    LOOP
        -- ---- declared PK ----
        SELECT array_agg(a.attname ORDER BY k.ord), bool_and(i.indisvalid)
        INTO v_keys, v_pk_valid
        FROM pg_index i
        CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a
          ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        WHERE i.indrelid = v_tbl.oid
          AND i.indisprimary;

        IF v_keys IS NULL THEN
            v_violations := v_violations ||
                format('%I.%I: no declared primary key', v_schema, v_tbl.relname);
            CONTINUE;
        END IF;

        v_checked := v_checked + 1;

        IF NOT v_pk_valid THEN
            v_violations := v_violations ||
                format('%I.%I: primary key index is INVALID', v_schema, v_tbl.relname);
        END IF;

        SELECT string_agg(format('%I', k), ', '),
               string_agg(format('%I IS NULL', k), ' OR ')
        INTO v_col_list, v_null_cond
        FROM unnest(v_keys) AS k;

        SELECT string_agg(format('btrim(%I::text) = ''''', a.attname), ' OR ')
        INTO v_blank_cond
        FROM pg_attribute a
        WHERE a.attrelid = v_tbl.oid
          AND a.attname  = ANY (v_keys)
          AND a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype);

        RAISE NOTICE '%.%: checking PK (%)', v_schema, v_tbl.relname, v_col_list;

        -- ---- NULL PK values ----
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                       v_schema, v_tbl.relname, v_null_cond)
        INTO v_null_rows;

        IF v_null_rows > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with NULL in PK (%s)',
                       v_schema, v_tbl.relname, v_null_rows, v_col_list);
        END IF;

        -- ---- blank-string PK values ----
        IF v_blank_cond IS NOT NULL THEN
            EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                           v_schema, v_tbl.relname, v_blank_cond)
            INTO v_blank_rows;

            IF v_blank_rows > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s rows with blank PK value in (%s)',
                           v_schema, v_tbl.relname, v_blank_rows, v_col_list);
            END IF;
        END IF;

        -- ---- duplicate PK values (NULL rows already reported) ----
        EXECUTE format(
            'SELECT count(*), coalesce(sum(n - 1), 0)
             FROM (SELECT count(*) AS n
                   FROM %I.%I
                   WHERE NOT (%s)
                   GROUP BY %s
                   HAVING count(*) > 1) d',
            v_schema, v_tbl.relname, v_null_cond, v_col_list)
        INTO v_dup_keys, v_dup_rows;

        IF v_dup_keys > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s duplicated PK values (%s surplus rows) on (%s)',
                       v_schema, v_tbl.relname, v_dup_keys, v_dup_rows, v_col_list);
        END IF;

        -- ---- natural / business key uniqueness ----
        IF v_natural_keys ? v_tbl.relname THEN
            SELECT array_agg(x) INTO v_keys
            FROM jsonb_array_elements_text(v_natural_keys -> v_tbl.relname) AS x;

            SELECT string_agg(format('%I', k), ', '),
                   string_agg(format('%I IS NULL', k), ' OR ')
            INTO v_col_list, v_null_cond
            FROM unnest(v_keys) AS k;

            EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                           v_schema, v_tbl.relname, v_null_cond)
            INTO v_null_rows;

            IF v_null_rows > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s rows with NULL natural key (%s)',
                           v_schema, v_tbl.relname, v_null_rows, v_col_list);
            END IF;

            EXECUTE format(
                'SELECT count(*), coalesce(sum(n - 1), 0)
                 FROM (SELECT count(*) AS n
                       FROM %I.%I
                       WHERE NOT (%s)
                       GROUP BY %s
                       HAVING count(*) > 1) d',
                v_schema, v_tbl.relname, v_null_cond, v_col_list)
            INTO v_dup_keys, v_dup_rows;

            IF v_dup_keys > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s duplicated natural key values (%s surplus rows) on (%s)',
                           v_schema, v_tbl.relname, v_dup_keys, v_dup_rows, v_col_list);
            END IF;
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
        RAISE EXCEPTION E'Analytics primary key violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All primary key checks passed for schema % (% tables)', v_schema, v_checked;
END $$;
