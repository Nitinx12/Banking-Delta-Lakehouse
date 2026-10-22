-- ============================================================
-- Script Name : 01_lp_check_metadata_col.sql
-- Purpose     : Validate load metadata on every table in the
--               analytics schema. Fails with a single error that
--               lists all violations.
-- Checks      : 1. source_batch_id and source_row_updated_at exist
--                  (dim_txn_profile is a derived junk dimension and
--                  is exempt from the source columns)
--               2. source_row_updated_at is timestamptz (the source
--                  columns are nullable by design so the Unknown
--                  member can carry no lineage; the data-level NULL
--                  rule below excludes that row)
--               3. row_added_at / row_updated_at are timestamptz
--                  and NOT NULL
--               4. No NULL or blank source_batch_id
--               5. No NULL source_row_updated_at
--               6. No load timestamps in the future
--               7. Data is fresh (max row_updated_at within window)
-- Unknown rows : dimension rows with *_key = -1 are the Unknown
--                 member; they carry no source lineage by design
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_analytics_metadata_col(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema        CONSTANT TEXT     := 'analytics';
    v_max_staleness CONSTANT INTERVAL := INTERVAL '7 days';
    v_source_exempt CONSTANT TEXT[]   := ARRAY['dim_txn_profile']::TEXT[];  -- no source lineage columns

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
    v_violations  TEXT[] := ARRAY[]::TEXT[];
    v_run_id      BIGINT;
    v_tbl         RECORD;
    v_meta        RECORD;
    v_meta_found  INT;
    v_where       TEXT;
    v_type        TEXT;
    v_batch_ok    BOOLEAN;
    v_source_ok   BOOLEAN;
    v_null_batch  BIGINT;
    v_null_source BIGINT;
    v_null_added  BIGINT;
    v_null_upd    BIGINT;
    v_future      BIGINT;
    v_max_upd     TIMESTAMPTZ;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('analytics', '01_lp_check_metadata_col.sql', p_pipeline_run_id)
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
        v_where := CASE WHEN v_unknown_keys ? v_tbl.relname
                        THEN format('%I <> -1', v_unknown_keys ->> v_tbl.relname)
                        ELSE 'TRUE' END;

        -- ---- source_batch_id: existence ----
        SELECT format_type(a.atttypid, a.atttypmod)
        INTO v_type
        FROM pg_attribute a
        WHERE a.attrelid = v_tbl.oid
          AND a.attname  = 'source_batch_id'
          AND a.attnum   > 0
          AND NOT a.attisdropped;

        v_batch_ok := FOUND;
        IF NOT FOUND THEN
            IF v_tbl.relname <> ALL (v_source_exempt) THEN
                v_violations := v_violations ||
                    format('%I.%I: missing column source_batch_id', v_schema, v_tbl.relname);
            END IF;
        END IF;

        -- ---- source_row_updated_at: existence + type ----
        SELECT format_type(a.atttypid, a.atttypmod)
        INTO v_type
        FROM pg_attribute a
        WHERE a.attrelid = v_tbl.oid
          AND a.attname  = 'source_row_updated_at'
          AND a.attnum   > 0
          AND NOT a.attisdropped;

        v_source_ok := FOUND;
        IF NOT FOUND THEN
            IF v_tbl.relname <> ALL (v_source_exempt) THEN
                v_violations := v_violations ||
                    format('%I.%I: missing column source_row_updated_at', v_schema, v_tbl.relname);
            END IF;
        ELSE
            IF v_type <> 'timestamp with time zone' THEN
                v_violations := v_violations ||
                    format('%I.%I: source_row_updated_at is %s, expected timestamp with time zone',
                           v_schema, v_tbl.relname, v_type);
                v_source_ok := FALSE;
            END IF;
        END IF;

        -- ---- row_added_at / row_updated_at: type + NOT NULL ----
        v_meta_found := 0;
        FOR v_meta IN
            SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS type_name, a.attnotnull
            FROM pg_attribute a
            WHERE a.attrelid = v_tbl.oid
              AND a.attname IN ('row_added_at', 'row_updated_at')
              AND a.attnum > 0
              AND NOT a.attisdropped
        LOOP
            v_meta_found := v_meta_found + 1;
            IF v_meta.type_name <> 'timestamp with time zone' THEN
                v_violations := v_violations ||
                    format('%I.%I.%I: type is %s, expected timestamp with time zone',
                           v_schema, v_tbl.relname, v_meta.attname, v_meta.type_name);
            END IF;
            IF NOT v_meta.attnotnull THEN
                v_violations := v_violations ||
                    format('%I.%I.%I: not declared NOT NULL', v_schema, v_tbl.relname, v_meta.attname);
            END IF;
        END LOOP;

        IF v_meta_found <> 2 THEN
            v_violations := v_violations ||
                format('%I.%I: expected row_added_at and row_updated_at, found %s of them',
                       v_schema, v_tbl.relname, v_meta_found);
        END IF;

        -- ---- load timestamps: nulls and future values ----
        EXECUTE format(
            'SELECT count(*) FILTER (WHERE row_added_at IS NULL),
                    count(*) FILTER (WHERE row_updated_at IS NULL),
                    count(*) FILTER (WHERE row_updated_at > now() + interval ''5 minutes''
                                      OR row_added_at > now() + interval ''5 minutes''),
                    max(row_updated_at)
             FROM %I.%I WHERE %s', v_schema, v_tbl.relname, v_where)
        INTO v_null_added, v_null_upd, v_future, v_max_upd;

        IF v_null_added > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with NULL row_added_at', v_schema, v_tbl.relname, v_null_added);
        END IF;
        IF v_null_upd > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with NULL row_updated_at', v_schema, v_tbl.relname, v_null_upd);
        END IF;
        IF v_future > 0 THEN
            v_violations := v_violations ||
                format('%I.%I: %s rows with load timestamps in the future', v_schema, v_tbl.relname, v_future);
        END IF;
        IF v_max_upd IS NOT NULL AND v_max_upd < now() - v_max_staleness THEN
            v_violations := v_violations ||
                format('%I.%I: stale data, latest row_updated_at is %s (limit %s)',
                       v_schema, v_tbl.relname, v_max_upd, v_max_staleness);
        END IF;

        -- ---- source columns: nulls, blanks, future values ----
        IF v_source_ok THEN
            EXECUTE format(
                'SELECT count(*) FILTER (WHERE source_row_updated_at IS NULL),
                        count(*) FILTER (WHERE source_row_updated_at > now() + interval ''5 minutes'')
                 FROM %I.%I WHERE %s', v_schema, v_tbl.relname, v_where)
            INTO v_null_source, v_future;

            IF v_null_source > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s rows with NULL source_row_updated_at',
                           v_schema, v_tbl.relname, v_null_source);
            END IF;
            IF v_future > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s rows with source_row_updated_at in the future',
                           v_schema, v_tbl.relname, v_future);
            END IF;
        END IF;

        IF v_batch_ok THEN
            EXECUTE format(
                'SELECT count(*) FROM %I.%I
                 WHERE %s AND (source_batch_id IS NULL OR btrim(source_batch_id::text) = '''')',
                v_schema, v_tbl.relname, v_where)
            INTO v_null_batch;

            IF v_null_batch > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s rows with NULL or blank source_batch_id',
                           v_schema, v_tbl.relname, v_null_batch);
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
        RAISE EXCEPTION E'Analytics metadata column violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All metadata columns passed in schema %', v_schema;
END $$;
