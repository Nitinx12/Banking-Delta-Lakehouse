-- ============================================================
-- Script:     00_create_database.sql
-- Run: psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f .\sql\metadata\01_raw_tables.sql
-- ============================================================
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'raw'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;
