
-- Purpose: Inspect indexes across all schemas

SELECT
    schemaname AS schema_name,
    tablename AS table_name,
    indexname AS index_name,
    indexdef AS index_definition
FROM pg_catalog.pg_indexes
WHERE schemaname NOT IN ('information_schema', 'pg_catalog')
  AND schemaname NOT LIKE 'pg_toast%'
ORDER BY schemaname, tablename, indexname;
