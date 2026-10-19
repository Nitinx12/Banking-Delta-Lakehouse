-- ============================================================
-- Script:     05_switch_mongo_databricks_incremental.sql
-- Purpose:    Flip MongoDB + Databricks tables from full to incremental
--             load. MySQL tables stay full. Does NOT touch
--             audit.extract_watermarks — seed those afterwards with
--             python scripts/seed_watermarks.py.
-- Execute against: banking_delta
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\scripts\05_switch_mongo_databricks_incremental.sql
-- ============================================================

DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;
END $$;

-- MongoDB: _id is the only monotonic, indexed field (created_at/loaded_at are
-- plain strings in these collections, so they cannot be timestamp watermarks).
UPDATE audit.source_tables AS t
SET load_strategy      = 'incremental',
    incremental_column = '_id',
    watermark_strategy = 'objectid'
FROM audit.source_registry AS r
WHERE r.source_id = t.source_id
  AND r.source_name = 'mongodb_source'
  AND t.source_table IN ('support_tickets', 'card_transactions');

-- Databricks: created_at is a real timestamp column on all three tables.
UPDATE audit.source_tables AS t
SET load_strategy      = 'incremental',
    incremental_column = 'created_at',
    watermark_strategy = 'timestamp'
FROM audit.source_registry AS r
WHERE r.source_id = t.source_id
  AND r.source_name = 'databricks_source'
  AND t.source_table IN ('loans', 'loan_payments', 'transactions');

-- MySQL stays full: business keys are stable, tables are small and upstream
-- rebuilds them, so a window would add risk without saving meaningful time.

-- Verify registration and extract-watermark state.
SELECT
    r.source_name,
    t.source_table,
    t.load_strategy,
    t.incremental_column,
    t.watermark_strategy,
    w.last_watermark_value
FROM audit.source_tables AS t
JOIN audit.source_registry AS r USING (source_id)
LEFT JOIN audit.extract_watermarks AS w USING (config_id)
ORDER BY r.source_name, t.source_table;
