
-- Purpose: List constraints across all schemas

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
