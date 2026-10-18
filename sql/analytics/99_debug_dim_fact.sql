-- ============================================================
-- Script:   99_debug_dim_fact.sql
-- Purpose:  Read-only debug of every analytics dim/fact table.
--           One text column, one line per check:  table | check | status | detail
-- Database: banking_delta
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\analytics\99_debug_dim_fact.sql
-- Statuses: OK = fine, WARN = investigate, FAIL = broken, INFO = context
-- ============================================================

-- Guards -------------------------------------------------------
DO $$
DECLARE
    v_missing TEXT;
BEGIN
    IF current_database() <> 'banking_delta' THEN
        RAISE EXCEPTION 'Run this script against banking_delta (connected to: %)', current_database();
    END IF;

    SELECT string_agg(t.x, ', ') INTO v_missing
    FROM (VALUES
        ('analytics.dim_customer'), ('analytics.dim_account'), ('analytics.dim_branch'),
        ('analytics.dim_employee'), ('analytics.dim_card'), ('analytics.dim_loan'),
        ('analytics.dim_txn_profile'), ('analytics.fact_card_transactions'),
        ('analytics.fact_loan_payments'), ('analytics.fact_transactions'),
        ('analytics.fact_support_tickets'), ('staging.scd1_history'),
        ('audit.table_runs'), ('audit.pipeline_errors')
    ) AS t(x)
    WHERE to_regclass(t.x) IS NULL;

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Missing tables: % - run the analytics scripts first.', v_missing;
    END IF;
END $$;

-- dim_customer -------------------------------------------------
SELECT 'analytics.dim_customer | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' WHEN n <= 1 THEN 'WARN' ELSE 'OK' END ||
       ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_customer) t
UNION ALL
SELECT 'analytics.dim_customer | unknown_member | ' ||
       CASE WHEN n = 1 THEN 'OK' ELSE 'FAIL' END || ' | rows_with_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_customer WHERE customer_key = -1) t
UNION ALL
SELECT 'analytics.dim_customer | natural_key_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_customer_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT customer_id FROM analytics.dim_customer GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.dim_customer | gender_null | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | null_gender=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_customer WHERE gender IS NULL) t
UNION ALL
SELECT 'analytics.dim_customer | derived_unknown | ' || 'INFO' ||
       ' | age_band=' || a || ' income_band=' || b || ' credit_band=' || c
FROM (
    SELECT count(*) FILTER (WHERE age_band   = 'Unknown') AS a,
           count(*) FILTER (WHERE income_band = 'Unknown') AS b,
           count(*) FILTER (WHERE credit_band = 'Unknown') AS c
    FROM analytics.dim_customer WHERE customer_key <> -1
) t
UNION ALL
SELECT 'analytics.dim_customer | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO'
            WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN'
            ELSE 'OK' END ||
       ' | dim_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.dim_customer) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.customers) s
UNION ALL
SELECT 'analytics.dim_customer | null_lineage | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END || ' | null_source_row_updated_at=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_customer WHERE customer_key <> -1 AND source_row_updated_at IS NULL) t

-- dim_account --------------------------------------------------
UNION ALL
SELECT 'analytics.dim_account | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' WHEN n <= 1 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_account) t
UNION ALL
SELECT 'analytics.dim_account | unknown_member | ' ||
       CASE WHEN n = 1 THEN 'OK' ELSE 'FAIL' END || ' | rows_with_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_account WHERE account_key = -1) t
UNION ALL
SELECT 'analytics.dim_account | natural_key_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_account_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT account_id FROM analytics.dim_account GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.dim_account | orphan_fk | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | customer_key_not_in_dim_customer=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_account d LEFT JOIN analytics.dim_customer c USING (customer_key)
      WHERE d.customer_key <> -1 AND c.customer_key IS NULL) t
UNION ALL
SELECT 'analytics.dim_account | late_arriving_backlog | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END || ' | rows_with_customer_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_account WHERE customer_key = -1 AND account_id <> -1) t
UNION ALL
SELECT 'analytics.dim_account | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO' WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN' ELSE 'OK' END ||
       ' | dim_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.dim_account) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.accounts) s

-- dim_branch ---------------------------------------------------
UNION ALL
SELECT 'analytics.dim_branch | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' WHEN n <= 1 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_branch) t
UNION ALL
SELECT 'analytics.dim_branch | unknown_member | ' ||
       CASE WHEN n = 1 THEN 'OK' ELSE 'FAIL' END || ' | rows_with_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_branch WHERE branch_key = -1) t
UNION ALL
SELECT 'analytics.dim_branch | natural_key_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_branch_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT branch_id FROM analytics.dim_branch GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.dim_branch | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO' WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN' ELSE 'OK' END ||
       ' | dim_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.dim_branch) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.branches) s

-- dim_employee -------------------------------------------------
UNION ALL
SELECT 'analytics.dim_employee | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' WHEN n <= 1 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_employee) t
UNION ALL
SELECT 'analytics.dim_employee | unknown_member | ' ||
       CASE WHEN n = 1 THEN 'OK' ELSE 'FAIL' END || ' | rows_with_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_employee WHERE employee_key = -1) t
UNION ALL
SELECT 'analytics.dim_employee | natural_key_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_employee_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT employee_id FROM analytics.dim_employee GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.dim_employee | orphan_fk | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | branch_key_not_in_dim_branch=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_employee e LEFT JOIN analytics.dim_branch b USING (branch_key)
      WHERE e.branch_key <> -1 AND b.branch_key IS NULL) t
UNION ALL
SELECT 'analytics.dim_employee | late_arriving_backlog | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END || ' | rows_with_branch_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_employee WHERE branch_key = -1 AND employee_id <> -1) t
UNION ALL
SELECT 'analytics.dim_employee | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO' WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN' ELSE 'OK' END ||
       ' | dim_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.dim_employee) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.employees) s

-- dim_card -----------------------------------------------------
UNION ALL
SELECT 'analytics.dim_card | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' WHEN n <= 1 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_card) t
UNION ALL
SELECT 'analytics.dim_card | unknown_member | ' ||
       CASE WHEN n = 1 THEN 'OK' ELSE 'FAIL' END || ' | rows_with_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_card WHERE card_key = -1) t
UNION ALL
SELECT 'analytics.dim_card | natural_key_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_card_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT card_id FROM analytics.dim_card GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.dim_card | orphan_fk | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END ||
       ' | account_key_missing=' || a || ' customer_key_missing=' || b
FROM (
    SELECT count(*) FILTER (WHERE d.account_key <> -1 AND a.account_key IS NULL) AS a,
           count(*) FILTER (WHERE d.customer_key <> -1 AND c.customer_key IS NULL) AS b
    FROM analytics.dim_card d
    LEFT JOIN analytics.dim_account a USING (account_key)
    LEFT JOIN analytics.dim_customer c USING (customer_key)
) t
UNION ALL
SELECT 'analytics.dim_card | late_arriving_backlog | ' ||
       CASE WHEN a + b = 0 THEN 'OK' ELSE 'WARN' END ||
       ' | account_-1=' || a || ' customer_-1=' || b
FROM (
    SELECT count(*) FILTER (WHERE account_key = -1 AND card_id <> -1) AS a,
           count(*) FILTER (WHERE customer_key = -1 AND card_id <> -1) AS b
    FROM analytics.dim_card
) t
UNION ALL
SELECT 'analytics.dim_card | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO' WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN' ELSE 'OK' END ||
       ' | dim_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.dim_card) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.cards) s

-- dim_loan -----------------------------------------------------
UNION ALL
SELECT 'analytics.dim_loan | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' WHEN n <= 1 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_loan) t
UNION ALL
SELECT 'analytics.dim_loan | unknown_member | ' ||
       CASE WHEN n = 1 THEN 'OK' ELSE 'FAIL' END || ' | rows_with_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_loan WHERE loan_key = -1) t
UNION ALL
SELECT 'analytics.dim_loan | natural_key_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_loan_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT loan_id FROM analytics.dim_loan GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.dim_loan | orphan_fk | ' ||
       CASE WHEN a + b = 0 THEN 'OK' ELSE 'FAIL' END ||
       ' | customer_key_missing=' || a || ' branch_key_missing=' || b
FROM (
    SELECT count(*) FILTER (WHERE d.customer_key <> -1 AND c.customer_key IS NULL) AS a,
           count(*) FILTER (WHERE d.branch_key <> -1 AND b.branch_key IS NULL) AS b
    FROM analytics.dim_loan d
    LEFT JOIN analytics.dim_customer c USING (customer_key)
    LEFT JOIN analytics.dim_branch b USING (branch_key)
) t
UNION ALL
SELECT 'analytics.dim_loan | late_arriving_backlog | ' ||
       CASE WHEN a + b = 0 THEN 'OK' ELSE 'WARN' END ||
       ' | customer_-1=' || a || ' branch_-1=' || b
FROM (
    SELECT count(*) FILTER (WHERE customer_key = -1 AND loan_id <> -1) AS a,
           count(*) FILTER (WHERE branch_key = -1 AND loan_id <> -1) AS b
    FROM analytics.dim_loan
) t
UNION ALL
SELECT 'analytics.dim_loan | maturity_date | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END || ' | null_maturity_with_terms=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_loan
      WHERE loan_id <> -1 AND start_date IS NOT NULL AND term_months IS NOT NULL AND maturity_date IS NULL) t
UNION ALL
SELECT 'analytics.dim_loan | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO' WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN' ELSE 'OK' END ||
       ' | dim_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.dim_loan) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.loans) s

-- dim_txn_profile ----------------------------------------------
UNION ALL
SELECT 'analytics.dim_txn_profile | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' WHEN n = 1 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_txn_profile) t
UNION ALL
SELECT 'analytics.dim_txn_profile | unknown_member | ' ||
       CASE WHEN n = 1 THEN 'OK' ELSE 'FAIL' END || ' | rows_with_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.dim_txn_profile WHERE txn_profile_key = -1) t
UNION ALL
SELECT 'analytics.dim_txn_profile | natural_key_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_combinations=' || n
FROM (SELECT count(*) AS n FROM (SELECT txn_type, channel, merchant_category
      FROM analytics.dim_txn_profile GROUP BY 1, 2, 3 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.dim_txn_profile | combination_coverage | ' ||
       CASE WHEN st.n > dp.n THEN 'WARN' ELSE 'OK' END ||
       ' | staging_distinct=' || st.n || ' dim_distinct=' || dp.n
FROM (SELECT count(*) AS n FROM (SELECT DISTINCT COALESCE(txn_type,'Unknown'), COALESCE(channel,'Unknown'),
      COALESCE(merchant_category,'Unknown') FROM staging.transactions) s) st
CROSS JOIN (SELECT count(*) AS n FROM analytics.dim_txn_profile WHERE txn_profile_key <> -1) dp

-- fact_card_transactions ---------------------------------------
UNION ALL
SELECT 'analytics.fact_card_transactions | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_card_transactions) t
UNION ALL
SELECT 'analytics.fact_card_transactions | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_card_txn_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT card_txn_id FROM analytics.fact_card_transactions
      GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.fact_card_transactions | orphan_fk | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | card_key_not_in_dim_card=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_card_transactions f
      LEFT JOIN analytics.dim_card c USING (card_key)
      WHERE f.card_key <> -1 AND c.card_key IS NULL) t
UNION ALL
SELECT 'analytics.fact_card_transactions | late_arriving_backlog | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END || ' | rows_with_card_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_card_transactions WHERE card_key = -1) t
UNION ALL
SELECT 'analytics.fact_card_transactions | date_key_consistency | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | mismatched_date_key=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_card_transactions
      WHERE date_key IS DISTINCT FROM COALESCE(TO_CHAR(txn_date, 'YYYYMMDD')::INT, -1)) t
UNION ALL
SELECT 'analytics.fact_card_transactions | amount_negative | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END || ' | negative_amounts=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_card_transactions WHERE amount < 0) t
UNION ALL
SELECT 'analytics.fact_card_transactions | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO' WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN' ELSE 'OK' END ||
       ' | fact_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.fact_card_transactions) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.card_transactions) s

-- fact_loan_payments -------------------------------------------
UNION ALL
SELECT 'analytics.fact_loan_payments | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_loan_payments) t
UNION ALL
SELECT 'analytics.fact_loan_payments | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_payment_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT payment_id FROM analytics.fact_loan_payments
      GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.fact_loan_payments | orphan_fk | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | loan_key_not_in_dim_loan=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_loan_payments f
      LEFT JOIN analytics.dim_loan l USING (loan_key)
      WHERE f.loan_key <> -1 AND l.loan_key IS NULL) t
UNION ALL
SELECT 'analytics.fact_loan_payments | late_arriving_backlog | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END || ' | rows_with_loan_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_loan_payments WHERE loan_key = -1) t
UNION ALL
SELECT 'analytics.fact_loan_payments | date_key_consistency | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | mismatched_date_key=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_loan_payments
      WHERE date_key IS DISTINCT FROM COALESCE(TO_CHAR(payment_date, 'YYYYMMDD')::INT, -1)) t
UNION ALL
SELECT 'analytics.fact_loan_payments | amount_check_values | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | invalid_amount_check=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_loan_payments
      WHERE amount_check NOT IN ('OK', 'DERIVED', 'MISMATCH', 'INCOMPLETE')) t
UNION ALL
SELECT 'analytics.fact_loan_payments | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO' WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN' ELSE 'OK' END ||
       ' | fact_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.fact_loan_payments) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.loan_payments) s

-- fact_transactions --------------------------------------------
UNION ALL
SELECT 'analytics.fact_transactions | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_transactions) t
UNION ALL
SELECT 'analytics.fact_transactions | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_transaction_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT transaction_id FROM analytics.fact_transactions
      GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.fact_transactions | orphan_fk | ' ||
       CASE WHEN a + b = 0 THEN 'OK' ELSE 'FAIL' END ||
       ' | account_key_missing=' || a || ' profile_key_missing=' || b
FROM (
    SELECT count(*) FILTER (WHERE f.account_key <> -1 AND a.account_key IS NULL) AS a,
           count(*) FILTER (WHERE f.txn_profile_key <> -1 AND p.txn_profile_key IS NULL) AS b
    FROM analytics.fact_transactions f
    LEFT JOIN analytics.dim_account a USING (account_key)
    LEFT JOIN analytics.dim_txn_profile p USING (txn_profile_key)
) t
UNION ALL
SELECT 'analytics.fact_transactions | late_arriving_backlog | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END || ' | rows_with_account_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_transactions WHERE account_key = -1) t
UNION ALL
SELECT 'analytics.fact_transactions | date_key_consistency | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | mismatched_date_key=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_transactions
      WHERE date_key IS DISTINCT FROM COALESCE(TO_CHAR(txn_date, 'YYYYMMDD')::INT, -1)) t
UNION ALL
SELECT 'analytics.fact_transactions | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO' WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN' ELSE 'OK' END ||
       ' | fact_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.fact_transactions) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.transactions) s

-- fact_support_tickets -----------------------------------------
UNION ALL
SELECT 'analytics.fact_support_tickets | rows | ' ||
       CASE WHEN n = 0 THEN 'FAIL' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_support_tickets) t
UNION ALL
SELECT 'analytics.fact_support_tickets | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_ticket_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT ticket_id FROM analytics.fact_support_tickets
      GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'analytics.fact_support_tickets | orphan_fk | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | customer_key_not_in_dim_customer=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_support_tickets f
      LEFT JOIN analytics.dim_customer c USING (customer_key)
      WHERE f.customer_key <> -1 AND c.customer_key IS NULL) t
UNION ALL
SELECT 'analytics.fact_support_tickets | late_arriving_backlog | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END || ' | rows_with_customer_key_-1=' || n
FROM (SELECT count(*) AS n FROM analytics.fact_support_tickets WHERE customer_key = -1) t
UNION ALL
SELECT 'analytics.fact_support_tickets | date_key_consistency | ' ||
       CASE WHEN a + b = 0 THEN 'OK' ELSE 'FAIL' END ||
       ' | bad_opened_key=' || a || ' bad_resolved_key=' || b
FROM (
    SELECT count(*) FILTER (WHERE opened_date_key IS DISTINCT FROM COALESCE(TO_CHAR(date_opened, 'YYYYMMDD')::INT, -1)) AS a,
           count(*) FILTER (WHERE resolved_date_key IS DISTINCT FROM COALESCE(TO_CHAR(date_resolved, 'YYYYMMDD')::INT, -1)) AS b
    FROM analytics.fact_support_tickets
) t
UNION ALL
SELECT 'analytics.fact_support_tickets | measure_sanity | ' ||
       CASE WHEN a + b = 0 THEN 'OK' ELSE 'FAIL' END ||
       ' | negative_resolution_days=' || a || ' score_out_of_range=' || b
FROM (
    SELECT count(*) FILTER (WHERE resolution_days < 0) AS a,
           count(*) FILTER (WHERE satisfaction_score IS NOT NULL AND satisfaction_score NOT BETWEEN 1 AND 5) AS b
    FROM analytics.fact_support_tickets
) t
UNION ALL
SELECT 'analytics.fact_support_tickets | watermark_lag | ' ||
       CASE WHEN s.max_src IS NULL THEN 'INFO' WHEN d.max_wm IS NULL THEN 'WARN'
            WHEN s.max_src > d.max_wm THEN 'WARN' ELSE 'OK' END ||
       ' | fact_wm=' || COALESCE(d.max_wm::TEXT, '-') || ' staging_max=' || COALESCE(s.max_src::TEXT, '-')
FROM (SELECT max(source_row_updated_at) AS max_wm FROM analytics.fact_support_tickets) d
CROSS JOIN (SELECT max(row_updated_at) AS max_src FROM staging.support_tickets) s

-- audit: latest table_runs row per analytics target ------------
UNION ALL
SELECT 'audit.table_runs | ' || v.target || ' | ' || COALESCE(t.status, 'MISSING') ||
       ' | rows_landed=' || COALESCE(t.rows_landed::TEXT, '-') ||
       ' wm_end=' || COALESCE(t.watermark_end, '-') ||
       ' ended=' || COALESCE(t.ended_at::TEXT, '-')
FROM (VALUES
        ('analytics.dim_customer'), ('analytics.dim_account'), ('analytics.dim_branch'),
        ('analytics.dim_employee'), ('analytics.dim_card'), ('analytics.dim_loan'),
        ('analytics.dim_txn_profile'), ('analytics.fact_card_transactions'),
        ('analytics.fact_loan_payments'), ('analytics.fact_transactions'),
        ('analytics.fact_support_tickets')
     ) AS v(target)
CROSS JOIN (SELECT 1) seed
LEFT JOIN LATERAL (
    SELECT tr.status, tr.rows_landed, tr.watermark_end, tr.ended_at
    FROM audit.table_runs tr
    WHERE tr.target_table = v.target
    ORDER BY tr.started_at DESC
    LIMIT 1
) t ON TRUE

-- audit: open errors per analytics target ----------------------
UNION ALL
SELECT 'audit.pipeline_errors | ' || v.target || ' | ' ||
       CASE WHEN COALESCE(e.n, 0) = 0 THEN 'OK' ELSE 'FAIL' END ||
       ' | open_errors=' || COALESCE(e.n, 0)
FROM (VALUES
        ('analytics.dim_customer'), ('analytics.dim_account'), ('analytics.dim_branch'),
        ('analytics.dim_employee'), ('analytics.dim_card'), ('analytics.dim_loan'),
        ('analytics.dim_txn_profile'), ('analytics.fact_card_transactions'),
        ('analytics.fact_loan_payments'), ('analytics.fact_transactions'),
        ('analytics.fact_support_tickets')
     ) AS v(target)
LEFT JOIN (
    SELECT target_table, count(*) AS n
    FROM audit.pipeline_errors
    WHERE resolution_status = 'OPEN'
    GROUP BY target_table
) e ON e.target_table = v.target

-- audit: stuck RUNNING runs (any layer) ------------------------
UNION ALL
SELECT 'audit.table_runs | stuck_running | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END ||
       ' | running_over_1h=' || n
FROM (SELECT count(*) AS n FROM audit.table_runs
      WHERE status = 'RUNNING' AND started_at < clock_timestamp() - INTERVAL '1 hour') t

-- history volume per analytics table ---------------------------
UNION ALL
SELECT 'staging.scd1_history | ' || h.table_name || ' | INFO | history_rows=' || h.n
FROM (SELECT table_name, count(*) AS n FROM staging.scd1_history
      WHERE table_name LIKE 'analytics.%' GROUP BY table_name) h;
