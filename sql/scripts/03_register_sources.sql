-- ============================================================
-- Script: 03_register_sources.sql
--- Run: psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f .\sql\scripts\03_register_sources.sql
-- ============================================================

-- Register source systems without duplicating existing entries.
INSERT INTO audit.sources (source_name, source_type)
VALUES
    ('mongodb_source', 'mongodb'),
    ('mysql_source', 'mysql'),
    ('databricks_source', 'databricks')
ON CONFLICT (source_name) DO NOTHING;

-- Verify source registration.
SELECT source_id, source_name, source_type, enabled
FROM audit.sources
ORDER BY source_id;
