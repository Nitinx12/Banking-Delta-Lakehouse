-- ============================================================
-- Script: 01_init_schemas.sql
-- Purpose: Initialize the five project schemas.
-- Execute against: banking_delta
-- Idempotent: Yes\
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\scripts\01_init_schemas.sql
-- ============================================================

-- Raw: Store source data with minimal transformations.
CREATE SCHEMA IF NOT EXISTS raw;

-- Staging: Clean, standardize, and deduplicate source data.
CREATE SCHEMA IF NOT EXISTS staging;

-- Analytics: Maintain reusable business data models.
CREATE SCHEMA IF NOT EXISTS analytics;

-- Marts: Store reporting-ready datasets for BI.
CREATE SCHEMA IF NOT EXISTS marts;

-- Audit: Store pipeline logs, errors, and data quality results.
CREATE SCHEMA IF NOT EXISTS audit;

-- Set the default schema resolution order for new sessions.
-- Explicit schema qualification is still recommended.
ALTER DATABASE banking_delta
    SET search_path TO marts, analytics, staging, raw, audit, public;

-- Verify that all five schemas exist.
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name IN (
    'audit',
    'raw',
    'staging',
    'analytics',
    'marts'
)
ORDER BY schema_name;

-- Expected: Five rows returned.
