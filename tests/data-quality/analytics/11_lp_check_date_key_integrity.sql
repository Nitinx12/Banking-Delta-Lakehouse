-- ============================================================
-- Script Name : 11_lp_check_date_key_integrity.sql
-- Purpose     : Validate the warehouse date keys (YYYYMMDD integers)
--               on every analytics fact. One error lists all
--               violations.
-- Checks      : 1. date key column and date column both exist
--               2. date key is never NULL
--               3. date key is -1 exactly when the date is NULL
--               4. date key is inside the sane calendar window
--               5. date key equals the date formatted as YYYYMMDD
--                  (catches 20260230 and other non-existent days,
--                  since the round trip must be exact)
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_date_key_check(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'analytics';

    -- [fact_table, date_key_column, date_column]
    v_date_keys CONSTANT JSONB := '[
        ["fact_card_transactions", "date_key",          "txn_date"],
        ["fact_transactions",      "date_key",          "txn_date"],
        ["fact_loan_payments",     "date_key",          "payment_date"],
        ["fact_support_tickets",   "opened_date_key",   "date_opened"],
        ["fact_support_tickets",   "resolved_date_key", "date_resolved"]
    ]';

    v_min_key CONSTANT INTEGER := 19000101;
    v_max_key CONSTANT INTEGER := 21001231;

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_rule       RECORD;
    v_missing    TEXT[];
    v_null_keys  BIGINT;
    v_orphan     BIGINT;
    v_outside    BIGINT;
    v_bad        BIGINT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('analytics', '11_lp_check_date_key_integrity.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    FOR v_rule IN
        SELECT e ->> 0 AS tbl, e ->> 1 AS key_col, e ->> 2 AS date_col
        FROM jsonb_array_elements(v_date_keys) AS e
    LOOP
        SELECT array_agg(format('%I.%I', x.tbl, x.col) ORDER BY x.tbl, x.col)
        INTO v_missing
        FROM (VALUES (v_rule.tbl, v_rule.key_col),
                     (v_rule.tbl, v_rule.date_col)) AS x(tbl, col)
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema AND c.relname = x.tbl
              AND a.attname = x.col AND a.attnum > 0 AND NOT a.attisdropped
        );

        IF v_missing IS NOT NULL THEN
            v_violations := v_violations ||
                format('config error: column(s) not found: %s', array_to_string(v_missing, ', '));
            CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT count(*) FILTER (WHERE %1$I IS NULL),
                   count(*) FILTER (WHERE (%2$I IS NULL) <> (%1$I = -1)),
                   count(*) FILTER (WHERE %1$I <> -1 AND (%1$I < %3$s OR %1$I > %4$s)),
                   count(*) FILTER (WHERE %1$I <> -1
                                    AND %2$I IS NOT NULL
                                    AND %1$I <> to_char(%2$I, 'YYYYMMDD')::int)
            FROM %5$I.%6$I
        $q$, v_rule.key_col, v_rule.date_col, v_min_key, v_max_key, v_schema, v_rule.tbl)
        INTO v_null_keys, v_orphan, v_outside, v_bad;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%.% / %: nulls=%s mismatched=-1/s=%s outside=%s bad=%s',
            v_schema, v_rule.tbl, v_rule.key_col, v_rule.date_col,
            v_null_keys, v_orphan, v_outside, v_bad;

        IF v_null_keys > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s NULL date keys',
                       v_schema, v_rule.tbl, v_rule.key_col, v_null_keys);
        END IF;
        IF v_orphan > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s rows where -1 does not agree with %I being NULL',
                       v_schema, v_rule.tbl, v_rule.key_col, v_orphan, v_rule.date_col);
        END IF;
        IF v_outside > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s keys outside %s..%s',
                       v_schema, v_rule.tbl, v_rule.key_col, v_outside, v_min_key, v_max_key);
        END IF;
        IF v_bad > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s keys do not match %I (not a valid YYYYMMDD day?)',
                       v_schema, v_rule.tbl, v_rule.key_col, v_bad, v_rule.date_col);
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
        RAISE EXCEPTION E'Analytics date key violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All date key checks passed: % key/date pairs in schema %',
        v_checked, v_schema;
END $$;
