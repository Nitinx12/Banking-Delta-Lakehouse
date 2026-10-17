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
-- Register the tables/collections to extract. Re-running is safe
-- (ON CONFLICT DO NOTHING). Adjust target_table if a name collides.
-- ------------------------------------------------------------

-- MongoDB (banking_support_db): full load, business key = _id
INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'banking_support_db', 'support_tickets', 'raw', 'support_tickets',
       '_id', 'full', 2
FROM audit.source_registry WHERE source_name = 'mongodb_source'
ON CONFLICT DO NOTHING;

INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'banking_support_db', 'card_transactions', 'raw', 'card_transactions',
       '_id', 'full', 4
FROM audit.source_registry WHERE source_name = 'mongodb_source'
ON CONFLICT DO NOTHING;

-- Databricks (schema 'public'): full load, landed name = table name
INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'public', 'loans', 'raw', 'loans',
       'loan_id', 'full', 2
FROM audit.source_registry WHERE source_name = 'databricks_source'
ON CONFLICT DO NOTHING;

INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'public', 'loan_payments', 'raw', 'loan_payments',
       'payment_id', 'full', 4
FROM audit.source_registry WHERE source_name = 'databricks_source'
ON CONFLICT DO NOTHING;

INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'public', 'transactions', 'raw', 'transactions',
       'transaction_id', 'full', 4
FROM audit.source_registry WHERE source_name = 'databricks_source'
ON CONFLICT DO NOTHING;

-- MySQL (banking_core_db): full load, business key = primary key
INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'banking_core_db', 'accounts', 'raw', 'accounts',
       'account_id', 'full', 4
FROM audit.source_registry WHERE source_name = 'mysql_source'
ON CONFLICT DO NOTHING;

INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'banking_core_db', 'branches', 'raw', 'branches',
       'branch_id', 'full', 1
FROM audit.source_registry WHERE source_name = 'mysql_source'
ON CONFLICT DO NOTHING;

INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'banking_core_db', 'cards', 'raw', 'cards',
       'card_id', 'full', 4
FROM audit.source_registry WHERE source_name = 'mysql_source'
ON CONFLICT DO NOTHING;

INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'banking_core_db', 'customers', 'raw', 'customers',
       'customer_id', 'full', 4
FROM audit.source_registry WHERE source_name = 'mysql_source'
ON CONFLICT DO NOTHING;

INSERT INTO audit.source_tables
    (source_id,
    source_schema,
    source_table,
    target_schema,
    target_table,
    business_key,
    load_strategy,
    num_partitions)
SELECT source_id, 'banking_core_db', 'employees', 'raw', 'employees',
       'employee_id', 'full', 2
FROM audit.source_registry WHERE source_name = 'mysql_source'
ON CONFLICT DO NOTHING;

-- Verify source registration.
SELECT
    source_id,
    source_name,
    source_type,
    is_enabled
FROM audit.source_registry
ORDER BY source_id;

-- Verify table registration.
SELECT
    r.source_name,
    t.source_schema,
    t.source_table,
    t.target_schema,
    t.target_table,
    t.load_strategy
FROM audit.source_tables t
JOIN audit.source_registry r USING (source_id)
ORDER BY r.source_name, t.source_table;
