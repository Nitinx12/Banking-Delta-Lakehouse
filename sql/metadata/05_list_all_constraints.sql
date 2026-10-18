-- ============================================================
-- Script:   05_list_all_constraints.sql
-- Purpose:  List constraints for user tables across schemas.
-- Database: banking_delta
-- Output:   Schema, table, constraint name, and type.
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\metadata\05_list_all_constraints.sql
-- ============================================================

SELECT
    tc.constraint_schema AS schema_name,
    tc.table_name,
    tc.constraint_name,
    tc.constraint_type
FROM information_schema.table_constraints AS tc
WHERE tc.constraint_schema NOT IN (
    'information_schema',
    'pg_catalog'
)
ORDER BY
    tc.constraint_schema,
    tc.table_name,
    tc.constraint_type,
    tc.constraint_name;
