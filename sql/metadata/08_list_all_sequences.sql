
-- Purpose: List sequences across all schemas

SELECT
    sequence_schema AS schema_name,
    sequence_name,
    data_type,
    start_value,
    minimum_value,
    maximum_value,
    increment
FROM information_schema.sequences
WHERE sequence_schema NOT IN (
    'information_schema',
    'pg_catalog'
)
ORDER BY sequence_schema, sequence_name;
