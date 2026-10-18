-- ============================================================
-- Script:   99_debug_staging.sql
-- Purpose:  Read-only debug of every staging table and its audit trail.
--           One text column, one line per check:  table | check | status | detail
-- Database: banking_delta
-- Run: psql -U postgres -d banking_delta -v ON_ERROR_STOP=1 -f .\sql\staging\99_debug_staging.sql
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
        ('staging.customers'), ('staging.accounts'), ('staging.branches'),
        ('staging.employees'), ('staging.cards'), ('staging.card_transactions'),
        ('staging.loans'), ('staging.loan_payments'), ('staging.transactions'),
        ('staging.support_tickets'), ('staging.scd1_history'),
        ('audit.table_runs'), ('audit.pipeline_errors'), ('audit.etl_watermarks')
    ) AS t(x)
    WHERE to_regclass(t.x) IS NULL;

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Missing tables: % - run 01_init_schemas / 02_audit_tables / staging scripts first.', v_missing;
    END IF;
END $$;

-- row counts + PK uniqueness per staging table ------------------
SELECT 'staging.customers | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.customers) t
UNION ALL
SELECT 'staging.customers | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_customer_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT customer_id FROM staging.customers GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'staging.customers | gender_values | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | invalid_gender=' || n
FROM (SELECT count(*) AS n FROM staging.customers WHERE gender NOT IN ('Male', 'Female', 'N/A')) t
UNION ALL
SELECT 'staging.accounts | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.accounts) t
UNION ALL
SELECT 'staging.accounts | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_account_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT account_id FROM staging.accounts GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'staging.branches | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.branches) t
UNION ALL
SELECT 'staging.branches | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_branch_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT branch_id FROM staging.branches GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'staging.employees | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.employees) t
UNION ALL
SELECT 'staging.employees | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_employee_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT employee_id FROM staging.employees GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'staging.cards | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.cards) t
UNION ALL
SELECT 'staging.cards | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_card_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT card_id FROM staging.cards GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'staging.card_transactions | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.card_transactions) t
UNION ALL
SELECT 'staging.card_transactions | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_card_txn_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT card_txn_id FROM staging.card_transactions GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'staging.loans | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.loans) t
UNION ALL
SELECT 'staging.loans | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_loan_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT loan_id FROM staging.loans GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'staging.loan_payments | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.loan_payments) t
UNION ALL
SELECT 'staging.loan_payments | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_payment_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT payment_id FROM staging.loan_payments GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'staging.loan_payments | amount_check_values | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | invalid_amount_check=' || n
FROM (SELECT count(*) AS n FROM staging.loan_payments
      WHERE amount_check IS NOT NULL
        AND amount_check NOT IN ('OK', 'DERIVED', 'MISMATCH', 'INCOMPLETE')) t
UNION ALL
SELECT 'staging.transactions | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.transactions) t
UNION ALL
SELECT 'staging.transactions | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_transaction_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT transaction_id FROM staging.transactions GROUP BY 1 HAVING count(*) > 1) d) t
UNION ALL
SELECT 'staging.support_tickets | rows | ' ||
       CASE WHEN n = 0 THEN 'WARN' ELSE 'OK' END || ' | count=' || n
FROM (SELECT count(*) AS n FROM staging.support_tickets) t
UNION ALL
SELECT 'staging.support_tickets | pk_dup | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'FAIL' END || ' | dup_ticket_id=' || n
FROM (SELECT count(*) AS n FROM (SELECT ticket_id FROM staging.support_tickets GROUP BY 1 HAVING count(*) > 1) d) t

-- watermark registry: one line per registered table -------------
UNION ALL
SELECT 'audit.etl_watermarks | ' || st.target_schema || '.' || st.target_table || ' | INFO' ||
       ' | wm_col=' || COALESCE(w.watermark_column, '-') ||
       ' last_wm=' || COALESCE(w.last_watermark_value, '<bootstrap>') ||
       ' lock_version=' || COALESCE(w.lock_version::TEXT, '0') ||
       ' last_success=' || COALESCE(w.last_success_at::TEXT, '-')
FROM audit.source_tables st
LEFT JOIN audit.etl_watermarks w ON w.config_id = st.config_id
WHERE st.is_enabled

-- latest table_runs row per staging target ----------------------
UNION ALL
SELECT 'audit.table_runs | ' || v.target || ' | ' || COALESCE(t.status, 'MISSING') ||
       ' | rows_landed=' || COALESCE(t.rows_landed::TEXT, '-') ||
       ' wm_end=' || COALESCE(t.watermark_end, '-') ||
       ' ended=' || COALESCE(t.ended_at::TEXT, '-')
FROM (VALUES
        ('staging.customers'), ('staging.accounts'), ('staging.branches'),
        ('staging.employees'), ('staging.cards'), ('staging.card_transactions'),
        ('staging.loans'), ('staging.loan_payments'), ('staging.transactions'),
        ('staging.support_tickets')
     ) AS v(target)
CROSS JOIN (SELECT 1) seed
LEFT JOIN LATERAL (
    SELECT tr.status, tr.rows_landed, tr.watermark_end, tr.ended_at
    FROM audit.table_runs tr
    WHERE tr.target_table = v.target
    ORDER BY tr.started_at DESC
    LIMIT 1
) t ON TRUE

-- open errors per staging target --------------------------------
UNION ALL
SELECT 'audit.pipeline_errors | ' || v.target || ' | ' ||
       CASE WHEN COALESCE(e.n, 0) = 0 THEN 'OK' ELSE 'FAIL' END ||
       ' | open_errors=' || COALESCE(e.n, 0)
FROM (VALUES
        ('staging.customers'), ('staging.accounts'), ('staging.branches'),
        ('staging.employees'), ('staging.cards'), ('staging.card_transactions'),
        ('staging.loans'), ('staging.loan_payments'), ('staging.transactions'),
        ('staging.support_tickets')
     ) AS v(target)
LEFT JOIN (
    SELECT target_table, count(*) AS n
    FROM audit.pipeline_errors
    WHERE resolution_status = 'OPEN'
    GROUP BY target_table
) e ON e.target_table = v.target

-- pipeline runs: manual vs orchestrated -------------------------
UNION ALL
SELECT 'audit.pipeline_runs | by_status | INFO | ' ||
       status || '=' || n
FROM (SELECT COALESCE(status, 'NULL') AS status, count(*) AS n
      FROM audit.pipeline_runs GROUP BY status) t

-- stuck RUNNING runs (any layer) --------------------------------
UNION ALL
SELECT 'audit.table_runs | stuck_running | ' ||
       CASE WHEN n = 0 THEN 'OK' ELSE 'WARN' END ||
       ' | running_over_1h=' || n
FROM (SELECT count(*) AS n FROM audit.table_runs
      WHERE status = 'RUNNING' AND started_at < clock_timestamp() - INTERVAL '1 hour') t

-- history volume per staging table ------------------------------
UNION ALL
SELECT 'staging.scd1_history | ' || h.table_name || ' | INFO | history_rows=' || h.n
FROM (SELECT table_name, count(*) AS n FROM staging.scd1_history
      WHERE table_name LIKE 'staging.%' GROUP BY table_name) h;
