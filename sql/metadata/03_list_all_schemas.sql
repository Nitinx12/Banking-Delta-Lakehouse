
-- Purpose: List all non-system schemas

SELECT
    schema_name,
    schema_owner
FROM information_schema.schemata
WHERE schema_name NOT IN ('information_schema', 'pg_catalog')
  AND schema_name NOT LIKE 'pg_toast%'
ORDER BY schema_name;
