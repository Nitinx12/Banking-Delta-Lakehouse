-- ============================================================
-- Script Name : 08_lp_check_completeness.sql
-- Purpose     : Fail if marts tables are empty, below their minimum
--               row count, do not cover their source dimension 1:1,
--               or have NULL/blank values in columns that must always
--               be populated. One error lists all violations.
-- Checks      : 1. Table is not empty
--               2. Table meets its configured minimum row count
--               3. Row-count coverage matches the source dimension
--                  for the grain-carrying marts (customer_360,
--                  branch_performance)
--               4. No NULL in any data column (outside v_null_ok)
--               5. No blank strings in any text column
-- Note        : mart_refreshed_at is covered by
--               01_lp_check_metadata_col.sql and is skipped here
-- Note        : Run with autocommit (psql, pg_cron, or the runner).
-- ============================================================

CREATE OR REPLACE PROCEDURE audit.dq_marts_completeness(p_pipeline_run_id UUID DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---------- configuration ----------
    v_schema   CONSTANT TEXT  := 'marts';
    v_min_rows CONSTANT JSONB := '{
        "mart_customer_360": 1000, "mart_branch_performance": 10,
        "mart_monthly_transactions": 1000, "mart_loan_portfolio": 10,
        "mart_card_fraud": 10, "mart_support_performance": 10,
        "mart_kpi_monthly": 12, "mart_loan_vintage": 10
    }'::JSONB;

    -- [mart_table, source_schema, source_table]
    v_coverage CONSTANT JSONB := '[
        ["mart_customer_360",       "analytics", "dim_customer"],
        ["mart_branch_performance", "analytics", "dim_branch"]
    ]'::JSONB;

    -- aggregate measures that are legitimately NULL when there is no
    -- underlying activity (e.g. a customer with no support tickets)
    v_null_ok CONSTANT TEXT[] := ARRAY[
        'mart_customer_360.annual_income', 'mart_customer_360.credit_score',
        'mart_customer_360.loan_to_income_ratio', 'mart_customer_360.avg_satisfaction_score',
        'mart_customer_360.avg_resolution_days', 'mart_customer_360.last_txn_date',
        'mart_customer_360.join_date', 'mart_customer_360.city',
        'mart_customer_360.state', 'mart_customer_360.occupation',
        'mart_branch_performance.avg_interest_rate',
        'mart_branch_performance.accounts_per_employee',
        'mart_branch_performance.late_payment_rate_pct',
        'mart_branch_performance.state', 'mart_branch_performance.city',
        'mart_branch_performance.ifsc_code', 'mart_branch_performance.opened_year',
        'mart_branch_performance.avg_salary',
        'mart_monthly_transactions.region', 'mart_monthly_transactions.state',
        'mart_loan_portfolio.avg_loan_amount', 'mart_loan_portfolio.avg_interest_rate',
        'mart_loan_portfolio.avg_term_months', 'mart_loan_portfolio.late_payment_rate_pct',
        'mart_loan_portfolio.start_year', 'mart_loan_portfolio.total_loan_amount',
        'mart_loan_portfolio.estimated_outstanding_principal',
        'mart_support_performance.avg_satisfaction_score',
        'mart_support_performance.avg_resolution_days',
        'mart_support_performance.max_resolution_days',
        'mart_support_performance.customer_state',
        'mart_kpi_monthly.avg_interest_rate', 'mart_kpi_monthly.avg_satisfaction_score',
        'mart_kpi_monthly.avg_resolution_days', 'mart_kpi_monthly.late_payment_rate_pct',
        'mart_kpi_monthly.avg_txn_amount', 'mart_kpi_monthly.fraud_rate_pct',
        'mart_kpi_monthly.ticket_resolution_rate_pct',
        'mart_kpi_monthly.txn_amount_mom_pct',
        'mart_kpi_monthly.card_spend_mom_pct', 'mart_kpi_monthly.loan_collections_mom_pct'
    ]::TEXT[];

    v_meta_cols CONSTANT TEXT[] := ARRAY['mart_refreshed_at'];

    -- ---------- working variables ----------
    v_violations TEXT[] := ARRAY[]::TEXT[];
    v_tbl        RECORD;
    v_cov        RECORD;
    v_col        RECORD;
    v_key        TEXT;
    v_rows       BIGINT;
    v_src_rows   BIGINT;
    v_bad        BIGINT;
    v_min        BIGINT;
    v_checked    INT := 0;
    v_run_id     BIGINT;
BEGIN
    INSERT INTO audit.dq_run (layer, script_name, pipeline_run_id)
    VALUES ('marts', '08_lp_check_completeness.sql', p_pipeline_run_id)
    RETURNING run_id INTO v_run_id;

    FOR v_tbl IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = v_schema
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
        ORDER BY c.relname
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I', v_schema, v_tbl.relname)
        INTO v_rows;

        -- ---- 1. not empty ----
        IF v_rows = 0 THEN
            v_violations := v_violations ||
                format('%I.%I: table is empty', v_schema, v_tbl.relname);
        END IF;

        -- ---- 2. minimum row count ----
        IF v_min_rows ? v_tbl.relname THEN
            v_min := (v_min_rows ->> v_tbl.relname)::bigint;
            IF v_rows < v_min THEN
                v_violations := v_violations ||
                    format('%I.%I: only %s rows, minimum is %s',
                           v_schema, v_tbl.relname, v_rows, v_min);
            END IF;
        ELSE
            v_violations := v_violations ||
                format('%I.%I: no minimum row count configured', v_schema, v_tbl.relname);
        END IF;

        -- ---- 4-5. per-column completeness ----
        FOR v_col IN
            SELECT a.attname,
                   a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype) AS is_text
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = v_schema
              AND c.relname = v_tbl.relname
              AND a.attnum  > 0
              AND NOT a.attisdropped
              AND a.attname <> ALL (v_meta_cols)
            ORDER BY a.attnum
        LOOP
            v_key := format('%s.%s', v_tbl.relname, v_col.attname);
            IF v_key = ANY (v_null_ok) THEN
                CONTINUE;
            END IF;

            EXECUTE format(
                'SELECT count(*) FROM %I.%I
                 WHERE %I IS NULL %s',
                v_schema, v_tbl.relname, v_col.attname,
                CASE WHEN v_col.is_text
                     THEN format('OR btrim(%I::text) = ''''', v_col.attname)
                     ELSE '' END)
            INTO v_bad;

            v_checked := v_checked + 1;

            IF v_bad > 0 THEN
                v_violations := v_violations ||
                    format('%I.%I.%I: %s NULL/blank rows',
                           v_schema, v_tbl.relname, v_col.attname, v_bad);
            END IF;
        END LOOP;
    END LOOP;

    -- ---- 3. coverage against the source dimension ----
    FOR v_cov IN
        SELECT e ->> 0 AS mart_tbl, e ->> 1 AS src_schema, e ->> 2 AS src_tbl
        FROM jsonb_array_elements(v_coverage) AS e
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I',
                       v_schema, v_cov.mart_tbl)
        INTO v_rows;
        EXECUTE format('SELECT count(*) FROM %I.%I',
                       v_cov.src_schema, v_cov.src_tbl)
        INTO v_src_rows;

        v_checked := v_checked + 1;
        RAISE NOTICE '%.%: % rows vs %.% (% rows)',
            v_schema, v_cov.mart_tbl, v_rows,
            v_cov.src_schema, v_cov.src_tbl, v_src_rows;

        IF v_rows <> v_src_rows THEN
            v_violations := v_violations ||
                format('%I.%I has %s rows but %I.%I has %s (missing coverage)',
                       v_schema, v_cov.mart_tbl, v_rows,
                       v_cov.src_schema, v_cov.src_tbl, v_src_rows);
        END IF;
    END LOOP;

    INSERT INTO audit.dq_violation (run_id, message)
    SELECT v_run_id, unnest(v_violations);

    UPDATE audit.dq_run
    SET finished_at     = now(),
        violation_count = cardinality(v_violations),
        status          = CASE WHEN cardinality(v_violations) = 0
                               THEN 'PASS' ELSE 'FAIL' END
    WHERE run_id = v_run_id;

    COMMIT;

    IF cardinality(v_violations) > 0 THEN
        RAISE EXCEPTION E'Marts completeness violations (%):\n%',
            cardinality(v_violations), array_to_string(v_violations, E'\n');
    END IF;

    RAISE NOTICE 'All completeness checks passed: % columns in schema %',
        v_checked, v_schema;
END $$;
