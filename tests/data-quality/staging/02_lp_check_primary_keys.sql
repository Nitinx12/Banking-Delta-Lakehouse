-- ============================================================
-- Script Name : 02_lp_check_primary_keys.sql
-- Purpose     : Validate primary keys on every table in the staging
--               schema. Fails with a single error that lists all
--               violations.
-- Key lookup  : 1. Declared primary key constraint
--               2. v_key_overrides (explicit business key)
--               3. Otherwise the table is reported as a violation
-- Checks      : 1. Key defined for every table
--               2. Declared PK index is valid
--               3. Configured key columns actually exist
--               4. No NULL values in any key column
--               5. No blank strings in text key columns
--               6. No duplicate key values
-- Note        : This is a PROCEDURE (not a DO block) so it can COMMIT,
--               letting the audit rows survive the final RAISE EXCEPTION.
--               Run with autocommit (psql, pg_cron, or run_staging_tests.py).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_staging_primary_key_check()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema         CONSTANT TEXT   := 'staging';
    v_exempt_tables  CONSTANT TEXT[] := ARRAY[]::TEXT[];
    v_key_overrides  CONSTANT JSONB  := '{
        "accounts":          ["account_id"],
        "branches":          ["branch_id"],
        "card_transactions": ["card_txn_id"],
        "cards":             ["card_id"],
        "customers":         ["customer_id"],
        "employees":         ["employee_id"],
        "loan_payments":     ["payment_id"],
        "loans":             ["loan_id"],
        "support_tickets":   ["ticket_id"],
        "transactions":      ["transaction_id"]
    }'::JSONB;

    -- ---------- working variables ----------
    v_violations  TEXT[] := ARRAY[]::TEXT[];
    v_run_id      BIGINT;
    v_tbl         RECORD;
    v_keys        TEXT[];
    v_pk_valid    BOOLEAN;
    v_source      TEXT;
    v_missing     TEXT[];
    v_col_list    TEXT;
    v_null_cond   TEXT;
    v_blank_cond  TEXT;
    v_null_rows   BIGINT;
    v_blank_rows  BIGINT;
    v_dup_keys    BIGINT;
    v_dup_rows    BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('staging', '02_lp_check_primary_keys.sql')
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
        v_keys := NULL;
        v_pk_valid := NULL;

        -- ---- 1a. declared PK ----
        SELECT array_agg(a.attname ORDER BY k.ord), bool_and(i.indisvalid)
        INTO v_keys, v_pk_valid
        FROM pg_index i
        CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a
          ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        WHERE i.indrelid = v_tbl.oid
          AND i.indisprimary;

        IF v_keys IS NOT NULL THEN
            v_source := 'declared PK';
            IF NOT v_pk_valid THEN
                v_violations := v_violations ||
                    format('%I.%I: primary key index is INVALID', v_schema, v_tbl.relname);
            END IF;

        -- ---- 1b. configured key ----
        ELSIF v_key_overrides ? v_tbl.relname THEN
            v_source := 'configured key';
            SELECT array_agg(x) INTO v_keys
            FROM jsonb_array_elements_text(v_key_overrides -> v_tbl.relname) AS x;

            SELECT array_agg(k) INTO v_missing
            FROM unnest(v_keys) AS k
            WHERE NOT EXISTS (
                SELECT 1 FROM pg_attribute a
                WHERE a.attrelid = v_tbl.oid
                  AND a.attname  = k
                  AND a.attnum   > 0
                  AND NOT a.attisdropped
            );

            IF v_missing IS NOT NULL THEN
                v_violations := v_violations ||
                    format('%I.%I: configured key column(s) not found: %s',
                           v_schema, v_tbl.relname, array_to_string(v_missing, ', '));
                CONTINUE;
            END IF;

        -- ---- 1c. no key defined ----
        ELSE
            v_violations := v_violations ||
                format('%I.%I: no primary key and no configured key (add it to v_key_overrides)',
                       v_schema, v_tbl.relname);
            CONTINUE;
        END IF;

        -- ---- build reusable SQL fragments ----
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

        RAISE NOTICE '%.%: checking key (%) [%]',
                     v_schema, v_tbl.relname, v_col_list, v_source;

        -- ---- 4. NULL keys ----
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                       v_schema, v_tbl.relname, v_null_cond)
        INTO v_null_rows;

        IF v_null_rows > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with NULL in key (%s) [%s]',
                       v_schema, v_tbl.relname, v_null_rows, v_col_list, v_source);
        END IF;

        -- ---- 5. blank-string keys ----
        IF v_blank_cond IS NOT NULL THEN
            EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                           v_schema, v_tbl.relname, v_blank_cond)
            INTO v_blank_rows;

            IF v_blank_rows > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s rows with blank key value in (%s) [%s]',
                           v_schema, v_tbl.relname, v_blank_rows, v_col_list, v_source);
            END IF;
        END IF;

        -- ---- 6. duplicate keys (NULL rows excluded, already reported) ----
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
                format('%I.%I: %s duplicated key values (%s surplus rows) on (%s) [%s]',
                       v_schema, v_tbl.relname, v_dup_keys, v_dup_rows, v_col_list, v_source);
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
        RAISE EXCEPTION E'Staging primary key violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All primary key checks passed for schema %', v_schema;
END $$;
