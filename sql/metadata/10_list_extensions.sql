
-- Purpose: List installed database extensions

SELECT
    e.extname AS extension_name,
    e.extversion AS extension_version,
    n.nspname AS schema_name
FROM pg_catalog.pg_extension AS e
JOIN pg_catalog.pg_namespace AS n
    ON n.oid = e.extnamespace
ORDER BY e.extname;
