-- ============================================================
-- Script:     03_register_sources.sql
-- Purpose:    Register the three source systems (no duplicates on re-run).
-- Execute against: banking_delta
-- Idempotent: Yes
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\scripts\03_register_sources.sql
-- ============================================================

DO $$
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;
END $$;

INSERT INTO audit.source_registry (source_name, source_type)
VALUES
    ('mongodb_source',    'mongodb'),
    ('mysql_source',      'mysql'),
    ('databricks_source', 'databricks')
ON CONFLICT (source_name) DO NOTHING;

-- ------------------------------------------------------------
-- TEMPLATE: register the tables/collections you want extracted.
-- Uncomment, edit, run. Re-running is safe (ON CONFLICT DO NOTHING).
-- ------------------------------------------------------------
-- INSERT INTO audit.source_tables
--     (source_id, source_schema, source_table, target_schema, target_table,
--      business_key, load_strategy, incremental_column, watermark_strategy,
--      partition_column, num_partitions)
-- SELECT source_id, 'bank_core', 'transactions', 'raw', 'mysql_transactions',
--        'txn_id', 'incremental', 'updated_at', 'timestamp',
--        'txn_id', 8
-- FROM audit.source_registry WHERE source_name = 'mysql_source'
-- ON CONFLICT DO NOTHING;
--
-- INSERT INTO audit.source_tables
--     (source_id, source_schema, source_table, target_table,
--      business_key, load_strategy, incremental_column, watermark_strategy)
-- SELECT source_id, 'bank_docs', 'customers', 'mongo_customers',
--        '_id', 'incremental', 'updated_at', 'timestamp'
-- FROM audit.source_registry WHERE source_name = 'mongodb_source'
-- ON CONFLICT DO NOTHING;

-- Verify source registration.
SELECT source_id, source_name, source_type, is_enabled
FROM audit.source_registry
ORDER BY source_id;
