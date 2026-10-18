-- ============================================================
-- Script:   08_list_all_sequences.sql
-- Purpose:  List user sequences across schemas.
-- Database: banking_delta
-- Output:   Sequence name, type, bounds, and increment.
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\metadata\08_list_all_sequences.sql
-- ============================================================

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
