-- ============================================================
-- Script:     00_create_database.sql
-- Purpose:    Create the project database if it does not exist.
-- Execute against: postgres   (the maintenance DB, NOT banking_delta)
-- Idempotent: Yes
-- Run: psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f .\sql\scripts\00_create_database.sql
-- ============================================================

SELECT 'CREATE DATABASE banking_delta'
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = 'banking_delta'
)\gexec
