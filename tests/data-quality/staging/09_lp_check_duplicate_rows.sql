-- ============================================================
-- Script Name : 09_lp_check_duplicate_rows.sql
-- Purpose     : Fail on accidental double-loads and broken
--               business-key uniqueness. One error lists all
--               violations.
-- Checks      : 1. No exact duplicate rows (same source values
--                  loaded more than once, ignoring ingestion
--                  metadata)
--               2. Configured business keys are unique
-- Note        : full-row duplicates are detected across every
--               non-metadata column, so two loads of the same
--               source row are caught even in different batches
-- Note        : This is a PROCEDURE (not a DO block) so it can COMMIT,
--               letting the audit rows survive the final RAISE EXCEPTION.
--               Run with autocommit (psql, pg_cron, or run_raw_tests.py).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_staging_duplicate_rows()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema CONSTANT TEXT := 'staging';
    -- [table, column] business keys that must be unique
    v_unique_keys CONSTANT JSONB := '[
        ["customers", "email"],
        ["branches",  "ifsc_code"]
    ]';
    v_meta_cols CONSTANT TEXT[] := ARRAY['_batch_id', '_loaded_at'];

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_tbl        RECORD;
    v_key        RECORD;
    v_col_list   TEXT;
    v_dup_groups BIGINT;
    v_dup_rows   BIGINT;
    v_examples   TEXT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('staging', '09_lp_check_duplicate_rows.sql')
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
        -- ---- 1. exact duplicate rows (all non-metadata columns) ----
        SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum)
        INTO v_col_list
        FROM pg_attribute a
        JOIN pg_class c     ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relname = v_tbl.relname
          AND a.attnum  > 0
          AND NOT a.attisdropped
          AND a.attname <> ALL (v_meta_cols);

        IF v_col_list IS NULL THEN
            CONTINUE;
        END IF;

        EXECUTE format($q$
            SELECT count(*), coalesce(sum(n - 1), 0)
            FROM (SELECT count(*) AS n
                  FROM %I.%I
                  GROUP BY %s
                  HAVING count(*) > 1) d
        $q$, v_schema, v_tbl.relname, v_col_list)
        INTO v_dup_groups, v_dup_rows;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%: % duplicate-row groups', v_schema, v_tbl.relname, v_dup_groups;

        IF v_dup_groups > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s surplus rows across %s duplicated row-groups',
                       v_schema, v_tbl.relname, v_dup_rows, v_dup_groups);
        END IF;
    END LOOP;

    -- ---- 2. business-key uniqueness ----
    FOR v_key IN
        SELECT e ->> 0 AS tbl, e ->> 1 AS col
        FROM jsonb_array_elements(v_unique_keys) AS e
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_key.tbl
              AND a.attname = v_key.col
              AND a.attnum  > 0
              AND NOT a.attisdropped
        ) THEN
            v_violations := v_violations ||
                format('config error: %I.%I.%I not found', v_schema, v_key.tbl, v_key.col);
            CONTINUE;
        END IF;

        EXECUTE format($q$
            WITH d AS (
                SELECT %1$I::text AS v
                FROM %2$I.%3$I
                WHERE %1$I IS NOT NULL
                GROUP BY %1$I
                HAVING count(*) > 1
            )
            SELECT count(*), array_to_string((array_agg(v))[1:3], ', ')
            FROM d
        $q$, v_key.col, v_schema, v_key.tbl)
        INTO v_dup_groups, v_examples;

        v_checked := v_checked + 1;

        IF v_dup_groups > 0 THEN
            v_violations := v_violations ||
                format('%I.%I.%I: %s duplicated values (e.g. %s)',
                       v_schema, v_key.tbl, v_key.col, v_dup_groups, v_examples);
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
        RAISE EXCEPTION E'Raw duplicate-row violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All duplicate-row checks passed: % checks in schema %',
        v_checked, v_schema;
END $$;

