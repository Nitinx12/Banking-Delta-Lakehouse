-- ============================================================
-- Script Name : 01_lp_check_metadata_col.sql
-- Purpose     : Validate refresh metadata on every table in the
--               marts schema. Fails with a single error that lists
--               all violations.
-- Checks      : 1. mart_refreshed_at exists on every mart
--               2. mart_refreshed_at is timestamptz
--               3. No NULL mart_refreshed_at
--               4. No refresh timestamps in the future
--               5. Data is fresh (max mart_refreshed_at within
--                  v_max_staleness)
-- Note        : marts are full-refresh CTAS tables, so they carry
--               mart_refreshed_at only; source_batch_id and the
--               row_added_at / row_updated_at lineage live in the
--               staging and analytics schemas
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_metadata_col(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema        CONSTANT TEXT     := 'marts';
    v_max_staleness CONSTANT INTERVAL := INTERVAL '7 days';

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_run_id     BIGINT;
    v_tbl        RECORD;
    v_type       TEXT;
    v_null_ts    BIGINT;
    v_future     BIGINT;
    v_max_ts     TIMESTAMPTZ;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('marts', '01_lp_check_metadata_col.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    FOR v_tbl IN
        SELECT c.oid, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
        ORDER BY c.relname
    LOOP
        -- ---- 1-2. mart_refreshed_at: existence + type ----
        SELECT format_type(a.atttypid, a.atttypmod)
        INTO v_type
        FROM pg_attribute a
        WHERE a.attrelid = v_tbl.oid
          AND a.attname  = 'mart_refreshed_at'
          AND a.attnum   > 0
          AND NOT a.attisdropped;

        IF NOT FOUND THEN
            v_violations := v_violations ||
                format('%I.%I: missing column mart_refreshed_at',
                       v_schema, v_tbl.relname);
            CONTINUE;
        END IF;

        IF v_type <> 'timestamp with time zone' THEN
            v_violations := v_violations ||
                format('%I.%I: mart_refreshed_at is %s, expected timestamp with time zone',
                       v_schema, v_tbl.relname, v_type);
            CONTINUE;
        END IF;

        -- ---- 3-5. NULL, future and stale refresh timestamps ----
        EXECUTE format(
            'SELECT count(*) FILTER (WHERE mart_refreshed_at IS NULL),
                    count(*) FILTER (WHERE mart_refreshed_at > now() + interval ''5 minutes''),
                    max(mart_refreshed_at)
             FROM %I.%I', v_schema, v_tbl.relname)
        INTO v_null_ts, v_future, v_max_ts;

        IF v_null_ts > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with NULL mart_refreshed_at',
                       v_schema, v_tbl.relname, v_null_ts);
        END IF;
        IF v_future > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with mart_refreshed_at in the future',
                       v_schema, v_tbl.relname, v_future);
        END IF;
        IF v_max_ts IS NOT NULL AND v_max_ts < now() - v_max_staleness THEN
            v_violations := v_violations ||
                format('%I.%I: stale data, latest mart_refreshed_at is %s (limit %s)',
                       v_schema, v_tbl.relname, v_max_ts, v_max_staleness);
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
        RAISE EXCEPTION E'Marts metadata column violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All metadata columns passed in schema %', v_schema;
END $$;
