-- ============================================================
-- Script Name : 02_object_counts.sql
-- Purpose     : Count procedures, functions, and triggers
-- Database    : PostgreSQL
-- Output      : Object type and total count across all schemas
-- ============================================================

SELECT
    'Stored Procedures' AS object_type,
    COUNT(*) AS total_count
FROM information_schema.routines
WHERE routine_type = 'PROCEDURE'
  AND routine_schema NOT IN ('information_schema', 'pg_catalog')

UNION ALL

SELECT
    'Functions' AS object_type,
    COUNT(*) AS total_count
FROM information_schema.routines
WHERE routine_type = 'FUNCTION'
  AND routine_schema NOT IN ('information_schema', 'pg_catalog')

UNION ALL

SELECT
    'Triggers' AS object_type,
    COUNT(*) AS total_count
FROM information_schema.triggers
WHERE trigger_schema NOT IN ('information_schema', 'pg_catalog')

ORDER BY object_type;
