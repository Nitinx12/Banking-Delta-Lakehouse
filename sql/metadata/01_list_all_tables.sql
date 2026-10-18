-- ============================================================
-- Script Name : 01_list_all_tables.sql
-- Purpose     : List all tables across all schemas
-- Database    : PostgreSQL
-- Output      : Schema name, table name, and table type
-- ============================================================

SELECT
    table_schema AS schema_name,
    table_name,
    table_type
FROM information_schema.tables
WHERE table_schema NOT IN (
    'information_schema',
    'pg_catalog'
)
ORDER BY
    table_schema,
    table_name;
