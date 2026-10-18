-- ============================================================
-- Script:   02_object_counts.sql
-- Purpose:  Count user procedures, functions, and triggers.
-- Database: banking_delta
-- Output:   Object type and total count across schemas.
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\metadata\02_object_counts.sql
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
