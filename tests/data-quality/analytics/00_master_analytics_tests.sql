-- ============================================================
-- Script Name : 00_master_analytics_tests.sql
-- Purpose     : Run every analytics-schema data-quality test with a
--               single CALL, in dependency order.
-- Order       : 01 metadata columns, 02 primary keys, 03 bad dates,
--               04 orphan rows, 05 business rules, 06 numeric ranges,
--               07 schema contract, 08 completeness, 09 duplicate
--               rows, 10 value domains, 11 date keys, 12 derived
--               attributes, 13 staging reconciliation
-- Behavior    : fail-fast - each test COMMITs its own audit rows
--               before raising, so a failure stops the sequence and
--               this run row is left unfinished; read the failing
--               test's audit.dq_run row for the cause
-- Run         : CALL audit.dq_master_analytics_tests();
--               or python scripts/run_analytics_tests.py --master
-- Note        : every test procedure COMMITs internally, so this
--               procedure must be invoked with autocommit (psql,
--               pg_cron, or the runner above)
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_master_analytics_tests()
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name)
    VALUES ('analytics', '00_master_analytics_tests.sql')
    RETURNING run_id INTO v_run_id;

    CALL audit.dq_analytics_metadata_col();
    CALL audit.dq_analytics_primary_key_check();
    CALL audit.dq_analytics_date_check();
    CALL audit.dq_analytics_orphan_rows_check();
    CALL audit.dq_analytics_business_rules();
    CALL audit.dq_analytics_numeric_ranges();
    CALL audit.dq_analytics_schema_contract();
    CALL audit.dq_analytics_completeness();
    CALL audit.dq_analytics_duplicate_rows();
    CALL audit.dq_analytics_value_domains();
    CALL audit.dq_analytics_date_key_check();
    CALL audit.dq_analytics_derived_attributes();
    CALL audit.dq_analytics_reconciliation();

    UPDATE audit.dq_run
    SET finished_at     = now(),
        violation_count = 0,
        status          = 'PASS'
    WHERE run_id = v_run_id;

    COMMIT;

    RAISE NOTICE 'Master analytics gate passed: 13 tests (run %)', v_run_id;
END $$;
