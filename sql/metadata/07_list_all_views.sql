-- ============================================================
-- Script:   07_list_all_views.sql
-- Purpose:  List user views and materialized views.
-- Database: banking_delta
-- Output:   Schema, view name, type, and owner.
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\metadata\07_list_all_views.sql
-- ============================================================

SELECT
    n.nspname AS schema_name,
    c.relname AS view_name,
    CASE c.relkind
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
    END AS view_type,
    pg_get_userbyid(c.relowner) AS owner
FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n
    ON n.oid = c.relnamespace
WHERE c.relkind IN ('v', 'm')
  AND n.nspname NOT IN ('information_schema', 'pg_catalog')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname, c.relname;
