-- ============================================================
-- Script Name : 05_lp_check_business_rules.sql
-- Purpose     : Validate logical/temporal consistency on the staging
--               schema. Fails with a single error that lists all
--               violations.
-- Checks      : 1. Intra-table date order (later >= earlier)
--               2. Arithmetic identity (components sum to total)
-- Note        : text date columns are compared after a guarded
--               cast; run 03_lp_check_bad_dates.sql first so the
--               text values are known to be valid ISO dates
-- Note        : the sum rule only applies where amount_check is OK
--               or DERIVED; MISMATCH rows are a sanctioned staging
--               state (sp_load_loan_payments reports them)
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_staging_business_rules(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'staging';

    -- [table, earlier_col, later_col] : later must be >= earlier
    v_order_rules CONSTANT JSONB := '[
        ["cards",           "issue_date",    "expiry_date"],
        ["customers",       "date_of_birth", "join_date"],
        ["support_tickets", "date_opened",   "date_resolved"]
    ]';

    -- [table, [component columns], total column, tolerance, scope condition]
    v_sum_rules CONSTANT JSONB := '[
        ["loan_payments", ["principal_component", "interest_component"], "amount_paid", 0.01,
         "amount_check IN (''OK'', ''DERIVED'')"]
    ]';

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_rule       RECORD;
    v_kind_c     TEXT;
    v_kind_p     TEXT;
    v_expr_c     TEXT;
    v_expr_p     TEXT;
    v_bad        BIGINT;
    v_examples   TEXT;
    v_parts      TEXT;
    v_tol        NUMERIC;
    v_cond       TEXT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('staging', '05_lp_check_business_rules.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    -- casts a text value to timestamp when it looks like an ISO date
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION pg_temp.biz_ts(p text)
        RETURNS timestamp LANGUAGE sql IMMUTABLE AS $f$
            SELECT CASE WHEN btrim(p) ~ '^\d{4}-\d{2}-\d{2}'
                        THEN btrim(p)::timestamp END;
        $f$;
    $fn$;

    -- column kind used to pick the comparison expression
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION pg_temp.biz_kind(p_schema text, p_tbl text, p_col text)
        RETURNS text LANGUAGE sql STABLE AS $f$
            SELECT CASE
                WHEN a.atttypid IN ('date'::regtype, 'timestamp'::regtype)     THEN 'ts'
                WHEN a.atttypid = 'timestamptz'::regtype                       THEN 'tz'
                WHEN a.atttypid IN ('text'::regtype, 'varchar'::regtype,
                                    'bpchar'::regtype)                         THEN 'txt'
                ELSE NULL
            END
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = p_schema
              AND c.relname = p_tbl
              AND a.attname = p_col
              AND a.attnum  > 0
              AND NOT a.attisdropped;
        $f$;
    $fn$;

    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION pg_temp.biz_expr(p_kind text, p_col text)
        RETURNS text LANGUAGE sql IMMUTABLE AS $f$
            SELECT CASE p_kind
                WHEN 'ts'  THEN format('%I', p_col)
                WHEN 'tz'  THEN format('(%I AT TIME ZONE ''UTC'')', p_col)
                WHEN 'txt' THEN format('pg_temp.biz_ts(%I::text)', p_col)
                ELSE NULL
            END;
        $f$;
    $fn$;

    -- ---- 1. intra-table date order ----
    FOR v_rule IN
        SELECT e ->> 0 AS tbl, e ->> 1 AS earlier, e ->> 2 AS later
        FROM jsonb_array_elements(v_order_rules) AS e
    LOOP
        v_kind_c := pg_temp.biz_kind(v_schema, v_rule.tbl, v_rule.earlier);
        v_kind_p := pg_temp.biz_kind(v_schema, v_rule.tbl, v_rule.later);

        IF v_kind_c IS NULL OR v_kind_p IS NULL THEN
            v_violations := v_violations ||
                format('config error: %s.%s date column(s) not found',
                       v_rule.tbl, v_rule.earlier || ', ' || v_rule.later);
            CONTINUE;
        END IF;

        v_expr_c := pg_temp.biz_expr(v_kind_c, v_rule.earlier);
        v_expr_p := pg_temp.biz_expr(v_kind_p, v_rule.later);

        EXECUTE format($q$
            SELECT count(*),
                   array_to_string((array_agg(DISTINCT %1$I::text))[1:3], ', ')
            FROM %2$I.%3$I
            WHERE %4$s IS NOT NULL AND %5$s IS NOT NULL AND %5$s < %4$s
        $q$, v_rule.later, v_schema, v_rule.tbl, v_expr_c, v_expr_p)
        INTO v_bad, v_examples;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%: % before % : % violations',
            v_schema, v_rule.tbl, v_rule.later, v_rule.earlier, v_bad;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s rows where %s < %s (e.g. %s)',
                       v_schema, v_rule.tbl, v_bad, v_rule.later, v_rule.earlier, v_examples);
        END IF;
    END LOOP;

    -- ---- 2. arithmetic identity: components sum to total ----
    FOR v_rule IN
        SELECT e ->> 0 AS tbl, e -> 1 AS parts, e ->> 2 AS total,
               (e ->> 3)::numeric AS tol, e ->> 4 AS cond
        FROM jsonb_array_elements(v_sum_rules) AS e
    LOOP
        v_tol  := coalesce(v_rule.tol, 0.01);
        v_cond := coalesce(nullif(v_rule.cond, ''), 'TRUE');

        SELECT string_agg(format('coalesce(%I, 0)', x), ' + ')
        INTO v_parts
        FROM jsonb_array_elements_text(v_rule.parts) AS x;

        EXECUTE format($q$
            SELECT count(*)
            FROM %1$I.%2$I
            WHERE %3$I IS NOT NULL AND abs(%3$I - (%4$s)) > %5$L
              AND %6$s
        $q$, v_schema, v_rule.tbl, v_rule.total, v_parts, v_tol, v_cond)
        INTO v_bad;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%: sum(%) vs % : % violations',
            v_schema, v_rule.tbl, v_parts, v_rule.total, v_bad;

        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%s.%s: %s rows where %s <> sum(%s) beyond %s',
                       v_schema, v_rule.tbl, v_bad, v_rule.total, v_parts, v_tol);
        END IF;
    END LOOP;

    DROP FUNCTION pg_temp.biz_ts(text);
    DROP FUNCTION pg_temp.biz_kind(text, text, text);
    DROP FUNCTION pg_temp.biz_expr(text, text);

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
        RAISE EXCEPTION E'Staging business rule violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All business rule checks passed: % rules in schema %',
        v_checked, v_schema;
END $$;
