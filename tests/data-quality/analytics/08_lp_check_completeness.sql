-- ============================================================
-- Script Name : 08_lp_check_completeness.sql
-- Purpose     : Fail if analytics tables are empty, below their
--               minimum row count, or have NULL/blank values in
--               columns that must always be populated. One error
--               lists all violations.
-- Checks      : 1. Table is not empty
--               2. Table meets its configured minimum row count
--               3. No NULL in any data column
--               4. No blank strings in any text column
-- Unknown rows : dimension rows with *_key = -1 are the Unknown
--                 member; they are sparse by design and are skipped
-- Note        : load metadata columns are covered by
--               01_lp_check_metadata_col.sql and are skipped here;
--               add columns that are legitimately optional to
--               v_null_ok
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_completeness()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema   CONSTANT TEXT  := 'analytics';
    v_min_rows CONSTANT JSONB := '{
        "dim_branch": 10, "dim_employee": 10, "dim_txn_profile": 10,
        "dim_customer": 1000, "dim_account": 1000, "dim_card": 1000,
        "dim_loan": 100, "fact_transactions": 1000,
        "fact_card_transactions": 1000, "fact_loan_payments": 1000,
        "fact_support_tickets": 100
    }'::JSONB;

    -- NULL allowed: credit limit has no meaning on debit cards
    v_null_ok CONSTANT TEXT[] := ARRAY['dim_card.credit_limit']::TEXT[];

    v_meta_cols CONSTANT TEXT[] := ARRAY['source_batch_id', 'source_row_updated_at', 'row_added_at', 'row_updated_at'];

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
    v_col        RECORD;
    v_key        TEXT;
    v_rows       BIGINT;
    v_bad        BIGINT;
    v_min        BIGINT;
    v_filter     TEXT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('analytics', '08_lp_check_completeness.sql')
    RETURNING run_id INTO v_run_id;

    FOR v_tbl IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
        ORDER BY c.relname
    LOOP
        v_filter := CASE WHEN v_unknown_keys ? v_tbl.relname
                         THEN format('%I <> -1', v_unknown_keys ->> v_tbl.relname)
                         ELSE 'TRUE' END;

        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s',
                       v_schema, v_tbl.relname, v_filter)
        INTO v_rows;

        -- ---- 1. not empty ----
        IF v_rows = 0 THEN
            v_violations := v_violations ||
                format('%I.%I: table is empty', v_schema, v_tbl.relname);
        END IF;

        -- ---- 2. minimum row count ----
        IF v_min_rows ? v_tbl.relname THEN
            v_min := (v_min_rows ->> v_tbl.relname)::bigint;
            IF v_rows < v_min THEN
                v_violations := v_violations ||
                    format('%I.%I: only %s rows, minimum is %s',
                           v_schema, v_tbl.relname, v_rows, v_min);
            END IF;
        ELSE
            v_violations := v_violations ||
                format('%I.%I: no minimum row count configured', v_schema, v_tbl.relname);
        END IF;

        -- ---- 3-4. per-column completeness ----
        FOR v_col IN
            SELECT a.attname,
                   a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype) AS is_text
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_tbl.relname
              AND a.attnum  > 0
              AND NOT a.attisdropped
              AND a.attname <> ALL (v_meta_cols)
            ORDER BY a.attnum
        LOOP
            v_key := format('%s.%s', v_tbl.relname, v_col.attname);
            IF v_key = ANY (v_null_ok) THEN
                CONTINUE;
            END IF;

            EXECUTE format(
                'SELECT count(*) FROM %I.%I
                 WHERE %s AND (%I IS NULL %s)',
                v_schema, v_tbl.relname, v_filter, v_col.attname,
                CASE WHEN v_col.is_text
                     THEN format('OR btrim(%I::text) = ''''', v_col.attname)
                     ELSE '' END)
            INTO v_bad;

            v_checked := v_checked + 1;

            IF v_bad > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I.%I: %s NULL/blank rows',
                           v_schema, v_tbl.relname, v_col.attname, v_bad);
            END IF;
        END LOOP;
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
        RAISE EXCEPTION E'Analytics completeness violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All completeness checks passed: % columns in schema %',
        v_checked, v_schema;
END $$;
