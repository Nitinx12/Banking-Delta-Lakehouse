-- ============================================================
-- Script:   09_list_table_sizes.sql
-- Purpose:  Report table and index storage usage.
-- Database: banking_delta
-- Output:   Table, data size, index size, and total size.
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\metadata\09_list_table_sizes.sql
-- ============================================================

SELECT
    schemaname AS schema_name,
    relname AS table_name,
    pg_size_pretty(
        pg_relation_size(relid)
    ) AS table_size,
    pg_size_pretty(
        pg_indexes_size(relid)
    ) AS indexes_size,
    pg_size_pretty(
        pg_total_relation_size(relid)
    ) AS total_size_bytes
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC;
