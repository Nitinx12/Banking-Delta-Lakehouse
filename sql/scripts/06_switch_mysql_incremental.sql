-- ============================================================
-- Script:     06_switch_mysql_incremental.sql
-- Purpose:    Flip MySQL tables from full to incremental load.
--             MySQL staging uses sp_load_*_scd1 procedures that
--             are watermark-based incremental SCD1 loads, so
--             load_strategy should be 'incremental'. This makes
--             the staging metadata freshness DQ check use the
--             last staging run time instead of source_loaded_at,
--             which only advances on INSERT/UPDATE (not on
--             unchanged rows).
-- Execute against: banking_delta
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\scripts\06_switch_mysql_incremental.sql
-- ============================================================

DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;
END $$;

UPDATE audit.source_tables AS t
SET load_strategy      = 'incremental',
    incremental_column = '_loaded_at',
    watermark_strategy = 'timestamp'
FROM audit.source_registry AS r
WHERE r.source_id = t.source_id
  AND r.source_name = 'mysql_source'
  AND t.source_table IN ('accounts', 'branches', 'cards', 'customers', 'employees');

-- Verify registration state.
SELECT
    r.source_name,
    t.source_table,
    t.load_strategy,
    t.incremental_column,
    t.watermark_strategy
FROM audit.source_tables AS t
JOIN audit.source_registry AS r USING (source_id)
WHERE r.source_name = 'mysql_source'
ORDER BY t.source_table;
