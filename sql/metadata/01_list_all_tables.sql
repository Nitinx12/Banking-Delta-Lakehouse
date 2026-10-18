-- ============================================================
-- Script:   01_list_all_tables.sql
-- Purpose:  List all user tables across schemas.
-- Database: banking_delta
-- Output:   Schema name, table name, and table type.
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\metadata\01_list_all_tables.sql
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
