-- ============================================================
-- Script Name : 00_master_raw_tests.sql
-- Purpose     : Run every raw-schema data-quality test with a
--               single CALL, in dependency order.
-- Order       : 01 metadata columns, 02 primary keys, 03 bad dates,
--               04 orphan rows, 05 business rules, 06 numeric ranges,
--               07 schema contract, 08 completeness, 09 duplicate
--               rows, 10 value domains
-- Behavior    : fail-fast - each test COMMITs its own audit rows
--               before raising, so a failure stops the sequence and
--               this run row is left unfinished; read the failing
--               test's audit.dq_run row for the cause
-- Run         : CALL audit.dq_master_raw_tests();
--               or python scripts/run_raw_tests.py --master
-- Note        : every test procedure COMMITs internally, so this
--               procedure must be invoked with autocommit (psql,
--               pg_cron, or the runner above)
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_master_raw_tests()
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('raw', '00_master_raw_tests.sql')
    RETURNING run_id INTO v_run_id;

    CALL audit.dq_raw_metadata_col();
    CALL audit.dq_raw_primary_key_check();
    CALL audit.dq_raw_date_check();
    CALL audit.dq_raw_orphan_rows_check();
    CALL audit.dq_raw_business_rules();
    CALL audit.dq_raw_numeric_ranges();
    CALL audit.dq_raw_schema_contract();
    CALL audit.dq_raw_completeness();
    CALL audit.dq_raw_duplicate_rows();
    CALL audit.dq_raw_value_domains();

    UPDATE audit.dq_run
    SET finished_at     = now(),
        violation_count = 0,
        status          = 'PASS'
    WHERE run_id = v_run_id;

    COMMIT;

    RAISE NOTICE 'Master raw gate passed: 10 tests (run %)', v_run_id;
END $$;
