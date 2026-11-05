-- ============================================================
-- Script Name : 00_lp_check_upstream_freshness.sql
-- Purpose     : Shared staleness helper for the analytics DQ
--               suite. Test 01 used to compare analytics
--               row_updated_at with the wall clock, which fails
--               quiet tables that are no older than the staging
--               table they were loaded from. This compares the
--               two layers instead, so only a real gap between
--               upstream and downstream counts as stale.
-- Function    : audit.dq_analytics_upstream_lag(p_table, p_max_updated)
-- Returns     : TEXT[] of violations, empty when the table is fine
-- Checks      : 1. analytics is not behind staging by more than
--                  1 hour (critical: test 01 appends it to its
--                  violations, which makes the gate RAISE)
--               2. no analytics rows for 30 days (warning only:
--                  a quiet source is not a quality failure)
-- Note        : Applied in numeric order, so it exists before
--               01_lp_check_metadata_col.sql calls it. The file
--               defines a function only, so the test runner
--               executes its DDL and never issues a CALL.
-- ============================================================

CREATE OR REPLACE FUNCTION audit.dq_analytics_upstream_lag(
    p_table       TEXT,
    p_max_updated TIMESTAMPTZ
)
RETURNS TEXT[]
LANGUAGE plpgsql
AS $$
DECLARE
    -- how far analytics may trail staging before it counts as behind
    v_lag_tolerance CONSTANT INTERVAL := INTERVAL '1 hour';
    -- silent for this long only warns: no rows is not a quality failure
    v_dead_limit    CONSTANT INTERVAL := INTERVAL '30 days';

    -- analytics table -> the staging table it is built from
    v_upstream CONSTANT JSONB := '{
        "dim_customer":          "customers",
        "dim_account":           "accounts",
        "dim_branch":            "branches",
        "dim_employee":          "employees",
        "dim_card":              "cards",
        "dim_loan":              "loans",
        "fact_card_transactions":"card_transactions",
        "fact_loan_payments":    "loan_payments",
        "fact_transactions":     "transactions",
        "fact_support_tickets":  "support_tickets"
    }'::JSONB;

    v_staging    TEXT;
    v_max_source TIMESTAMPTZ;
    v_violations TEXT[] := ARRAY[]::TEXT[];
BEGIN
    IF p_max_updated IS NULL THEN
        RETURN v_violations;  -- empty table: nothing to date against
    END IF;

    IF p_max_updated < now() - v_dead_limit THEN
        -- RAISE interpolates '%', unlike format(), which wants '%s'
        RAISE WARNING 'analytics.% has no row newer than % (latest row_updated_at %)',
            p_table, v_dead_limit, p_max_updated;
    END IF;

    v_staging := v_upstream ->> p_table;
    IF v_staging IS NULL THEN
        RETURN v_violations;  -- derived table with no staging twin
    END IF;

    EXECUTE format('SELECT max(row_updated_at) FROM staging.%I', v_staging)
    INTO v_max_source;

    IF v_max_source IS NULL THEN
        RETURN v_violations;  -- staging not loaded yet
    END IF;

    IF p_max_updated < v_max_source - v_lag_tolerance THEN
        v_violations := v_violations || format(
            '%I.%I: stale versus upstream, analytics is %s behind staging.%I (analytics %s, staging %s)',
            'analytics', p_table, v_max_source - p_max_updated, v_staging,
            p_max_updated, v_max_source
        );
    END IF;

    RETURN v_violations;
END $$;
