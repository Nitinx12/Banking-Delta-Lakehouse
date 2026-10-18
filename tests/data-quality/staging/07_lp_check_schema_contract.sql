-- ============================================================
-- Script Name : 07_lp_check_schema_contract.sql
-- Purpose     : Fail if any staging table has drifted from its
--               agreed column contract. One error lists all
--               violations.
-- Checks      : 1. Expected table exists
--               2. Every expected column exists
--               3. Column type family matches the contract
--               4. No unexpected data columns
--               5. Every staging table has a contract entry
-- Families    : int, num, text, date, flag, any
-- Note        : source passthrough timestamps (created_at, loaded_at)
--               and ingestion metadata are exempt from the extra
--               column check
-- Note        : This is a PROCEDURE (not a DO block) so it can COMMIT,
--               letting the audit rows survive the final RAISE EXCEPTION.
--               Run with autocommit (psql, pg_cron, or run_staging_tests.py).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_staging_schema_contract()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema       CONSTANT TEXT    := 'staging';
    v_forbid_extra CONSTANT BOOLEAN := TRUE;

    v_contract CONSTANT JSONB := '{
        "accounts": {"account_id":"int","customer_id":"int","branch_id":"int","account_type":"text","balance":"num","open_date":"date","status":"text"},
        "branches": {"branch_id":"int","branch_name":"text","city":"text","state":"text","opened_date":"date","ifsc_code":"text"},
        "cards": {"card_id":"int","customer_id":"int","account_id":"int","card_type":"text","issue_date":"date","expiry_date":"date","credit_limit":"num","status":"text"},
        "customers": {"customer_id":"int","customer_name":"text","gender":"text","date_of_birth":"date","city":"text","state":"text","phone":"text","email":"text","occupation":"text","annual_income":"num","join_date":"date","credit_score":"num"},
        "employees": {"employee_id":"int","employee_name":"text","branch_id":"int","role":"text","hire_date":"date","salary":"num"},
        "loans": {"loan_id":"int","customer_id":"int","branch_id":"int","loan_type":"text","loan_amount":"num","interest_rate":"num","term_months":"int","start_date":"date","status":"text"},
        "loan_payments": {"payment_id":"int","loan_id":"int","payment_date":"date","amount_paid":"num","principal_component":"num","interest_component":"num","is_late":"bool","amount_check":"text"},
        "transactions": {"transaction_id":"int","account_id":"int","txn_date":"date","txn_type":"text","amount":"num","channel":"text","merchant_category":"text"},
        "card_transactions": {"card_txn_id":"int","card_id":"int","merchant_category":"text","is_fraud":"bool","amount":"num","txn_date":"date"},
        "support_tickets": {"ticket_id":"int","customer_id":"int","issue_type":"text","date_opened":"date","date_resolved":"date","status":"text","satisfaction_score":"int"},
        "scd1_history": {"history_id":"int","table_name":"text","record_key":"text","changed_column":"text","old_value":"text","new_value":"text","source_batch_id":"text","table_run_id":"any","changed_at":"date"}
    }'::JSONB;

    v_meta_cols  CONSTANT TEXT[] := ARRAY['source_batch_id', 'source_loaded_at', 'row_added_at', 'row_updated_at'];
    v_passthru   CONSTANT TEXT[] := ARRAY['created_at', 'loaded_at'];  -- source-system timestamps kept for lineage

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_tbl        RECORD;
    v_col        RECORD;
    v_exists     BOOLEAN;
    v_type_name  TEXT;
    v_family     TEXT;
    v_ok         BOOLEAN;
    v_extra      TEXT[];
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('staging', '07_lp_check_schema_contract.sql')
    RETURNING run_id INTO v_run_id;

    FOR v_tbl IN
        SELECT key AS tbl, value AS cols FROM jsonb_each(v_contract)
    LOOP
        SELECT EXISTS (
            SELECT 1
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_tbl.tbl
              AND c.relkind IN ('r', 'p')
        )
        INTO v_exists;

        IF NOT v_exists THEN
            v_violations := v_violations ||
                format('%I.%I: table not found', v_schema, v_tbl.tbl);
            CONTINUE;
        END IF;

        FOR v_col IN
            SELECT key AS col, value #>> '{}' AS family FROM jsonb_each(v_tbl.cols)
        LOOP
            SELECT format_type(a.atttypid, a.atttypmod),
                   CASE
                       WHEN a.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype) THEN 'int'
                       WHEN a.atttypid IN ('numeric'::regtype, 'float4'::regtype, 'float8'::regtype) THEN 'num'
                       WHEN a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype) THEN 'text'
                       WHEN a.atttypid IN ('date'::regtype, 'timestamp'::regtype, 'timestamptz'::regtype) THEN 'date'
                       WHEN a.atttypid = 'bool'::regtype THEN 'bool'
                       ELSE 'other'
                   END
            INTO v_type_name, v_family
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_tbl.tbl
              AND a.attname = v_col.col
              AND a.attnum  > 0
              AND NOT a.attisdropped;

            IF NOT FOUND THEN
                v_violations := v_violations ||
                    format('%I.%I: missing column %I', v_schema, v_tbl.tbl, v_col.col);
                CONTINUE;
            END IF;

            v_checked := v_checked + 1;

            v_ok := v_col.family = v_family
                    OR (v_col.family = 'num'  AND v_family = 'int')
                    OR (v_col.family = 'flag' AND v_family IN ('int', 'num', 'text', 'bool'))
                    OR (v_col.family = 'any');

            IF NOT v_ok THEN
                v_violations := v_violations ||
                    format('%I.%I.%I: type is %s, contract expects %s',
                           v_schema, v_tbl.tbl, v_col.col, v_type_name, v_col.family);
            END IF;
        END LOOP;

        IF v_forbid_extra THEN
            SELECT array_agg(a.attname ORDER BY a.attnum)
            INTO v_extra
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_tbl.tbl
              AND a.attnum  > 0
              AND NOT a.attisdropped
              AND a.attname <> ALL (v_meta_cols || v_passthru)
              AND NOT (v_tbl.cols ? a.attname);

            IF v_extra IS NOT NULL THEN
                v_violations := v_violations ||
                    format('%I.%I: unexpected column(s): %s',
                           v_schema, v_tbl.tbl, array_to_string(v_extra, ', '));
            END IF;
        END IF;
    END LOOP;

    -- ---- 5. every staging table must be in the contract ----
    FOR v_tbl IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
          AND NOT (v_contract ? c.relname)
        ORDER BY c.relname
    LOOP
        v_violations := v_violations ||
            format('%I.%I: table has no contract entry', v_schema, v_tbl.relname);
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
        RAISE EXCEPTION E'staging schema contract violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All schema contract checks passed: % columns in schema %',
        v_checked, v_schema;
END $$;
