-- ============================================================
-- Script Name : 01_lp_check_metadata_col.sql
-- Purpose     : Validate ingestion metadata on every table in
--               the raw schema. Fails with a single error that
--               lists all violations.
-- Checks      : 1. _batch_id and _loaded_at exist
--               2. _loaded_at is timestamptz
--               3. Both columns are declared NOT NULL
--               4. No NULL or blank values in either column
--               5. No _loaded_at values in the future
--               6. Data is fresh (max _loaded_at within window; for
--                  incremental tables the last raw table run is used,
--                  because _loaded_at only advances when new rows land)
--               7. Optional: table has a PK or unique index
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_raw_metadata_col(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema         CONSTANT TEXT     := 'raw';
    v_max_staleness  CONSTANT INTERVAL := INTERVAL '24 hours';
    v_exempt_tables  CONSTANT TEXT[]   := ARRAY[]::TEXT[];  -- e.g. ARRAY['legacy_import']
    v_require_unique CONSTANT BOOLEAN  := FALSE;            -- TRUE = require PK/unique index

    -- ---------- working variables ----------
    v_violations   TEXT[] := ARRAY[]::TEXT[];
    v_run_id       BIGINT;
    v_tbl          RECORD;
    v_type         TEXT;
    v_notnull      BOOLEAN;
    v_batch_ok     BOOLEAN;
    v_loaded_ok    BOOLEAN;
    v_null_loaded  BIGINT;
    v_future       BIGINT;
    v_max_loaded   TIMESTAMPTZ;
    v_bad_batch    BIGINT;
    v_load_strategy TEXT;
    v_last_run_at   TIMESTAMPTZ;
    v_fresh_ts      TIMESTAMPTZ;
    v_fresh_label   TEXT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('raw', '01_lp_check_metadata_col.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    FOR v_tbl IN
        SELECT c.oid, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')        -- tables + partitioned parents
          AND NOT c.relispartition           -- skip individual partitions
          AND c.relname <> ALL (v_exempt_tables)
          AND c.relname NOT LIKE '\_stg\_%'  -- transient staging tables are not raw data
        ORDER BY c.relname
    LOOP
        v_batch_ok      := FALSE;
        v_loaded_ok     := FALSE;
        v_load_strategy := NULL;
        v_last_run_at   := NULL;

        -- ---- _batch_id: existence + NOT NULL ----
        SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull
        INTO v_type, v_notnull
        FROM pg_attribute a
        WHERE a.attrelid = v_tbl.oid
          AND a.attname  = '_batch_id'
          AND a.attnum   > 0
          AND NOT a.attisdropped;

        IF NOT FOUND THEN
            v_violations := v_violations ||
                format('%I.%I: missing column _batch_id', v_schema, v_tbl.relname);
        ELSE
            v_batch_ok := TRUE;
            IF NOT v_notnull THEN
                v_violations := v_violations ||
                    format('%I.%I: _batch_id is not declared NOT NULL', v_schema, v_tbl.relname);
            END IF;
        END IF;

        -- ---- _loaded_at: existence + type + NOT NULL ----
        SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull
        INTO v_type, v_notnull
        FROM pg_attribute a
        WHERE a.attrelid = v_tbl.oid
          AND a.attname  = '_loaded_at'
          AND a.attnum   > 0
          AND NOT a.attisdropped;

        IF NOT FOUND THEN
            v_violations := v_violations ||
                format('%I.%I: missing column _loaded_at', v_schema, v_tbl.relname);
        ELSE
            IF v_type <> 'timestamp with time zone' THEN
                v_violations := v_violations ||
                    format('%I.%I: _loaded_at is %s, expected timestamp with time zone',
                           v_schema, v_tbl.relname, v_type);
            ELSE
                v_loaded_ok := TRUE;
            END IF;
            IF NOT v_notnull THEN
                v_violations := v_violations ||
                    format('%I.%I: _loaded_at is not declared NOT NULL', v_schema, v_tbl.relname);
            END IF;
        END IF;

        -- ---- data checks: _loaded_at (nulls, future values, freshness) ----
        IF v_loaded_ok THEN
            EXECUTE format(
                'SELECT count(*) FILTER (WHERE _loaded_at IS NULL),
                        count(*) FILTER (WHERE _loaded_at > now() + interval ''5 minutes''),
                        max(_loaded_at)
                 FROM %I.%I', v_schema, v_tbl.relname)
            INTO v_null_loaded, v_future, v_max_loaded;

            IF v_null_loaded > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s rows with NULL _loaded_at',
                           v_schema, v_tbl.relname, v_null_loaded);
            END IF;
            IF v_future > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s rows with _loaded_at in the future',
                           v_schema, v_tbl.relname, v_future);
            END IF;

            -- Freshness: a full load rewrites _loaded_at every run, so it is a
            -- reliable "pipeline ran" signal. An incremental load only appends
            -- new source rows, so _loaded_at ages whenever the source is quiet;
            -- for those tables use the last raw table run instead.
            SELECT st.load_strategy INTO v_load_strategy
            FROM audit.source_tables st
            WHERE st.target_schema = v_schema
              AND st.target_table  = v_tbl.relname;

            IF COALESCE(v_load_strategy, 'full') = 'incremental' THEN
                SELECT max(tr.ended_at) INTO v_last_run_at
                FROM audit.table_runs tr
                WHERE tr.target_table     = v_schema || '.' || v_tbl.relname
                  AND tr.processing_layer = 'raw'
                  AND tr.ended_at IS NOT NULL;

                v_fresh_ts    := COALESCE(v_last_run_at, v_max_loaded);
                v_fresh_label := 'last raw run';
            ELSE
                v_fresh_ts    := v_max_loaded;
                v_fresh_label := 'latest _loaded_at';
            END IF;

            IF v_fresh_ts IS NOT NULL AND v_fresh_ts < now() - v_max_staleness THEN
                v_violations := v_violations ||
                    format('%I.%I: stale data, %s is %s (limit %s)',
                           v_schema, v_tbl.relname, v_fresh_label, v_fresh_ts,
                           v_max_staleness);
            END IF;
        END IF;

        -- ---- data checks: _batch_id (nulls / blanks) ----
        IF v_batch_ok THEN
            EXECUTE format(
                'SELECT count(*) FROM %I.%I
                 WHERE _batch_id IS NULL OR btrim(_batch_id::text) = ''''',
                v_schema, v_tbl.relname)
            INTO v_bad_batch;

            IF v_bad_batch > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I: %s rows with NULL or blank _batch_id',
                           v_schema, v_tbl.relname, v_bad_batch);
            END IF;
        END IF;

        -- ---- uniqueness: PK or unique index must exist ----
        IF v_require_unique AND NOT EXISTS (
            SELECT 1
            FROM pg_index i
            WHERE i.indrelid = v_tbl.oid
              AND (i.indisprimary OR i.indisunique)
              AND i.indisvalid
        ) THEN
            v_violations := v_violations ||
                format('%I.%I: no primary key or unique index', v_schema, v_tbl.relname);
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
        RAISE EXCEPTION E'Raw schema contract violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All metadata columns are pass %', v_schema;
END $$;
