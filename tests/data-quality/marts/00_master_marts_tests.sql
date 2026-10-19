-- ============================================================
-- Script Name : 00_master_marts_tests.sql
-- Purpose     : Run every marts-schema data-quality test with a
--               single CALL, in dependency order.
-- Order       : 01 metadata columns, 02 grain / keys, 03 bad dates,
--               04 orphan rows, 05 business rules, 06 numeric ranges,
--               07 schema contract, 08 completeness, 09 duplicate
--               rows, 10 value domains, 11 analytics reconciliation
-- Behavior    : fail-fast - each test COMMITs its own audit rows
--               before raising, so a failure stops the sequence and
--               this run row is left unfinished; read the failing
--               test's audit.dq_run row for the cause
-- Run         : CALL audit.dq_master_marts_tests();
--               or python scripts/run_marts_tests.py --master
-- Note        : every test procedure COMMITs internally, so this
--               procedure must be invoked with autocommit (psql,
--               pg_cron, or the runner above)
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_master_marts_tests()
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('marts', '00_master_marts_tests.sql')
    RETURNING run_id INTO v_run_id;

    CALL audit.dq_marts_metadata_col();
    CALL audit.dq_marts_primary_key_check();
    CALL audit.dq_marts_date_check();
    CALL audit.dq_marts_orphan_rows_check();
    CALL audit.dq_marts_business_rules();
    CALL audit.dq_marts_numeric_ranges();
    CALL audit.dq_marts_schema_contract();
    CALL audit.dq_marts_completeness();
    CALL audit.dq_marts_duplicate_rows();
    CALL audit.dq_marts_value_domains();
    CALL audit.dq_marts_reconciliation();

    UPDATE audit.dq_run
    SET finished_at     = now(),
        violation_count = 0,
        status          = 'PASS'
    WHERE run_id = v_run_id;

    COMMIT;

    RAISE NOTICE 'Master marts gate passed: 11 tests (run %)', v_run_id;
END $$;
