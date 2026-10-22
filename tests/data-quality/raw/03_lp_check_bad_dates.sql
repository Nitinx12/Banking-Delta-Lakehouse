-- ============================================================
-- Script Name : 03_lp_check_bad_dates.sql
-- Purpose     : Validate date/timestamp columns on every table in
--               the raw schema. Fails with a single error that
--               lists all violations.
-- Columns     : Checked if the type is date/timestamp/timestamptz,
--               OR the name matches v_name_pattern
--               (e.g. *_date, *_at, *_dt, dob)
-- Checks      : 1. Column has a real date/timestamp type
--               2. Text columns: no blank strings
--               3. Text columns: every value is a valid ISO date
--                  (catches 2026-02-30, 2026-13-01, 'N/A', 17/10/2026)
--               4. No infinity / -infinity values
--               5. No dates before v_min_date
--               6. No dates on/after v_max_date
--               7. No future dates, except columns where the future
--                  is legitimate (expiry, due, maturity, ...)
-- Performance : one scan per column, values parsed once per row,
--               parser has no EXCEPTION block (no subtransactions)
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_raw_date_check(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema           CONSTANT TEXT     := 'raw';
    v_exempt_tables    CONSTANT TEXT[]   := ARRAY[]::TEXT[];
    v_exempt_columns   CONSTANT TEXT[]   := ARRAY[]::TEXT[];  -- e.g. ARRAY['cards.card_note_at']

    v_name_pattern     CONSTANT TEXT     := '(_date|_dt|_at|_ts|_timestamp)$|^(dob|date_of_birth)$';

    v_future_ok_pattern CONSTANT TEXT    := '(expir|due|maturity|matures|next_|scheduled|valid_(to|until)|end_date)';
    v_future_ok_columns CONSTANT TEXT[]  := ARRAY[]::TEXT[];  -- e.g. ARRAY['loans.closing_date']

    v_min_date         CONSTANT DATE     := DATE '1900-01-01';
    v_max_date         CONSTANT DATE     := DATE '2100-01-01';
    v_tol_date         CONSTANT INTERVAL := INTERVAL '1 day';
    v_tol_ts           CONSTANT INTERVAL := INTERVAL '1 hour';
    v_tz               CONSTANT TEXT     := 'UTC';
    v_flag_text_type   CONSTANT BOOLEAN  := TRUE;

    -- ---------- working variables ----------
    v_violations  TEXT[] := ARRAY[]::TEXT[];
    v_col         RECORD;
    v_kind        TEXT;
    v_ref         TEXT;
    v_key         TEXT;
    v_parsed      TEXT;
    v_blank       TEXT;
    v_tol         INTERVAL;
    v_future_ok   BOOLEAN;
    v_checked     INT := 0;
    v_t0          TIMESTAMPTZ;
    v_blank_rows  BIGINT;
    v_bad_rows    BIGINT;
    v_inf_rows    BIGINT;
    v_old_rows    BIGINT;
    v_far_rows    BIGINT;
    v_future_rows BIGINT;
    v_max_future  TIMESTAMP;
    v_run_id      BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('raw', '03_lp_check_bad_dates.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    -- Safe parser for text columns. Returns NULL for anything that is not a
    -- real ISO date/timestamp. No EXCEPTION block: validation is done with a
    -- strict regex plus a days-in-month check, so it is fast and never throws.
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION pg_temp.raw_try_ts(p text, tz text)
        RETURNS timestamp LANGUAGE plpgsql STABLE AS $f$
        DECLARE
            y int; m int; d int; dim int;
        BEGIN
            IF p IS NULL THEN RETURN NULL; END IF;
            p := btrim(p);
            IF p ~* '^-?infinity$' THEN RETURN p::timestamp; END IF;

            IF p !~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])([ T]([01]\d|2[0-3]):[0-5]\d(:[0-5]\d(\.\d+)?)?(Z|[+-](0\d|1[0-5])(:?[0-5]\d)?)?)?$'
                THEN RETURN NULL;
            END IF;

            y := substr(p, 1, 4)::int;
            m := substr(p, 6, 2)::int;
            d := substr(p, 9, 2)::int;
            IF y < 1 THEN RETURN NULL; END IF;

            dim := CASE
                WHEN m IN (4, 6, 9, 11) THEN 30
                WHEN m = 2 THEN CASE WHEN (y % 4 = 0 AND y % 100 <> 0) OR y % 400 = 0
                                     THEN 29 ELSE 28 END
                ELSE 31
            END;
            IF d > dim THEN RETURN NULL; END IF;     -- 2026-02-30, 2026-04-31

            -- time part with explicit offset: convert to the storage zone
            IF p ~ '[ T]\d{2}:' AND p ~ '(Z|[+-]\d{2}(:?\d{2})?)$' THEN
                RETURN (p::timestamptz) AT TIME ZONE tz;
            END IF;
            RETURN p::timestamp;
        END
        $f$;
    $fn$;

    FOR v_col IN
        SELECT c.relname,
               a.attname,
               a.atttypid,
               format_type(a.atttypid, a.atttypmod) AS type_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid
                           AND a.attnum > 0
                           AND NOT a.attisdropped
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND c.relname <> ALL (v_exempt_tables)
          AND (c.relname || '.' || a.attname) <> ALL (v_exempt_columns)
          AND c.relname NOT LIKE '\_stg\_%'  -- transient staging tables are not raw data
          AND (a.atttypid IN ('date'::regtype, 'timestamp'::regtype, 'timestamptz'::regtype)
               OR a.attname ~* v_name_pattern)
        ORDER BY c.relname, a.attnum
    LOOP
        v_ref := format('%I.%I.%I', v_schema, v_col.relname, v_col.attname);
        v_key := v_col.relname || '.' || v_col.attname;

        v_kind := CASE
            WHEN v_col.atttypid = 'date'::regtype        THEN 'date'
            WHEN v_col.atttypid = 'timestamp'::regtype   THEN 'ts'
            WHEN v_col.atttypid = 'timestamptz'::regtype THEN 'tstz'
            WHEN v_col.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype) THEN 'text'
            ELSE 'other'
        END;

        -- ---- 1. type check ----
        IF v_kind = 'other' THEN
            v_violations := v_violations ||
                format('%s: looks like a date column but type is %s (expected date/timestamp)',
                       v_ref, v_col.type_name);
            CONTINUE;
        ELSIF v_kind = 'text' AND v_flag_text_type THEN
            v_violations := v_violations ||
                format('%s: stored as %s, expected date/timestamp', v_ref, v_col.type_name);
        END IF;

        v_parsed := CASE v_kind
            WHEN 'date' THEN format('%I::timestamp', v_col.attname)
            WHEN 'ts'   THEN format('%I', v_col.attname)
            WHEN 'tstz' THEN format('(%I AT TIME ZONE %L)', v_col.attname, v_tz)
            ELSE             format('pg_temp.raw_try_ts(%I::text, %L)', v_col.attname, v_tz)
        END;

        v_blank := CASE v_kind
            WHEN 'text' THEN format('btrim(%I::text) = ''''', v_col.attname)
            ELSE 'false'
        END;

        v_tol := CASE WHEN v_kind IN ('date', 'text') THEN v_tol_date ELSE v_tol_ts END;

        v_future_ok := v_col.attname ~* v_future_ok_pattern
                       OR v_key = ANY (v_future_ok_columns);

        RAISE NOTICE '%: checking [%]%', v_ref, v_col.type_name,
                     CASE WHEN v_future_ok THEN ' (future dates allowed)' ELSE '' END;
        v_checked := v_checked + 1;
        v_t0 := clock_timestamp();

        -- ---- 2-7. one scan per column, value parsed once per row ----
        EXECUTE format($q$
            WITH s AS MATERIALIZED (
                SELECT %6$s AS ts,
                       (%7$I IS NOT NULL) AS has_val,
                       %8$s AS is_blank
                FROM %9$I.%10$I
            )
            SELECT count(*) FILTER (WHERE is_blank),
                   count(*) FILTER (WHERE has_val AND NOT is_blank AND ts IS NULL),
                   count(*) FILTER (WHERE ts IN ('infinity'::timestamp, '-infinity'::timestamp)),
                   count(*) FILTER (WHERE ts > '-infinity'::timestamp AND ts < %1$L::timestamp),
                   count(*) FILTER (WHERE ts < 'infinity'::timestamp  AND ts >= %2$L::timestamp),
                   count(*) FILTER (WHERE NOT %3$s AND ts < %2$L::timestamp
                                      AND ts > (now() AT TIME ZONE %4$L) + %5$L::interval),
                   max(ts)  FILTER (WHERE NOT %3$s AND ts < %2$L::timestamp
                                      AND ts > (now() AT TIME ZONE %4$L) + %5$L::interval)
            FROM s
        $q$,
            v_min_date, v_max_date, v_future_ok::text, v_tz, v_tol,
            v_parsed, v_col.attname, v_blank, v_schema, v_col.relname)
        INTO v_blank_rows, v_bad_rows, v_inf_rows, v_old_rows, v_far_rows,
             v_future_rows, v_max_future;

        RAISE NOTICE '    done in %', clock_timestamp() - v_t0;

        IF v_blank_rows > 0 THEN
            v_violations := v_violations ||
                format('%s: %s blank string values', v_ref, v_blank_rows);
        END IF;
        IF v_bad_rows > 0 THEN
            v_violations := v_violations ||
                format('%s: %s values are not valid ISO dates (YYYY-MM-DD[ HH:MI[:SS]])',
                       v_ref, v_bad_rows);
        END IF;
        IF v_inf_rows > 0 THEN
            v_violations := v_violations ||
                format('%s: %s infinity / -infinity values', v_ref, v_inf_rows);
        END IF;
        IF v_old_rows > 0 THEN
            v_violations := v_violations ||
                format('%s: %s values before %s', v_ref, v_old_rows, v_min_date);
        END IF;
        IF v_far_rows > 0 THEN
            v_violations := v_violations ||
                format('%s: %s values on/after %s (placeholder dates?)',
                       v_ref, v_far_rows, v_max_date);
        END IF;
        IF v_future_rows > 0 THEN
            v_violations := v_violations ||
                format('%s: %s future values (latest %s)', v_ref, v_future_rows, v_max_future);
        END IF;
    END LOOP;

    IF v_checked = 0 THEN
        v_violations := v_violations ||
            format('no date columns found in schema %s - check v_name_pattern', v_schema);
    END IF;

    DROP FUNCTION pg_temp.raw_try_ts(text, text);

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
        RAISE EXCEPTION E'Raw date violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All date checks passed: % columns checked in schema %', v_checked, v_schema;
END $$;
