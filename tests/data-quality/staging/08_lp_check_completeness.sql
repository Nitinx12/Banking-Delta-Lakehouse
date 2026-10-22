-- ============================================================
-- Script Name : 08_lp_check_completeness.sql
-- Purpose     : Fail if staging tables are empty, below their minimum
--               row count, or have NULL/blank values in columns
--               that must always be populated. One error lists
--               all violations.
-- Checks      : 1. Table is not empty
--               2. Table meets its configured minimum row count
--               3. No NULL in any data column
--               4. No blank strings in any text column
-- Note        : metadata columns (source_batch_id, source_loaded_at,
--               row_added_at, row_updated_at) are covered by
--               01_lp_check_metadata_col.sql and are skipped here;
--               add columns that are legitimately optional to
--               v_null_ok, or conditional exceptions (NULL allowed
--               only under a condition) to v_null_ok_cond
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_staging_completeness(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema   CONSTANT TEXT   := 'staging';
    v_min_rows CONSTANT JSONB  := '{
        "accounts": 1000, "branches": 10, "cards": 1000, "customers": 1000,
        "employees": 10, "loans": 100, "loan_payments": 1000,
        "transactions": 1000, "card_transactions": 1000, "support_tickets": 100
    }'::JSONB;
    v_exempt_tables CONSTANT TEXT[] := ARRAY['scd1_history']::TEXT[];
    v_null_ok  CONSTANT TEXT[] := ARRAY[
        'cards.credit_limit',           -- NULL by design for non-Credit cards
        'support_tickets.date_resolved' -- NULL while the ticket is open
    ]::TEXT[];
    -- NULL allowed only while the condition holds (sp_load_loan_payments
    -- leaves a component NULL when amount_check is INCOMPLETE)
    v_null_ok_cond CONSTANT JSONB := '{
        "loan_payments.amount_paid":         "amount_check = ''INCOMPLETE''",
        "loan_payments.principal_component": "amount_check = ''INCOMPLETE''",
        "loan_payments.interest_component":  "amount_check = ''INCOMPLETE''"
    }'::JSONB;
    v_meta_cols CONSTANT TEXT[] := ARRAY['source_batch_id', 'source_loaded_at', 'row_added_at', 'row_updated_at'];

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_tbl        RECORD;
    v_col        RECORD;
    v_key        TEXT;
    v_rows       BIGINT;
    v_bad        BIGINT;
    v_min        BIGINT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('staging', '08_lp_check_completeness.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    FOR v_tbl IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname <> ALL (v_exempt_tables)
        ORDER BY c.relname
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I', v_schema, v_tbl.relname)
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
                 WHERE (%I IS NULL %s)
                   AND NOT COALESCE((%s), FALSE)',
                v_schema, v_tbl.relname, v_col.attname,
                CASE WHEN v_col.is_text
                     THEN format('OR btrim(%I::text) = ''''', v_col.attname)
                     ELSE '' END,
                COALESCE(v_null_ok_cond ->> v_key, 'FALSE'))
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
        RAISE EXCEPTION E'Staging completeness violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All completeness checks passed: % columns in schema %',
        v_checked, v_schema;
END $$;
