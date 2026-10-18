-- ============================================================
-- Script:   04_list_all_columns.sql
-- Purpose:  List columns for user tables across schemas.
-- Database: banking_delta
-- Output:   Table, column, type, nullability, and default.
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\metadata\04_list_all_columns.sql
-- ============================================================

SELECT
    table_schema AS schema_name,
    table_name,
    ordinal_position,
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_schema NOT IN ('information_schema', 'pg_catalog')
ORDER BY table_schema, table_name, ordinal_position;
