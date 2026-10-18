-- ============================================================
-- Script:   03_list_all_schemas.sql
-- Purpose:  List all non-system schemas.
-- Database: banking_delta
-- Output:   Schema name and owner.
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\metadata\03_list_all_schemas.sql
-- ============================================================

SELECT
    schema_name,
    schema_owner
FROM information_schema.schemata
WHERE schema_name NOT IN ('information_schema', 'pg_catalog')
  AND schema_name NOT LIKE 'pg_toast%'
ORDER BY schema_name;
