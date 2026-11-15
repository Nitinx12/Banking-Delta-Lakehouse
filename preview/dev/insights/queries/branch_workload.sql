-- Branch workload and collection spread from marts.mart_branch_performance.
SELECT
    COUNT(*) AS branches,
    ROUND(MIN(accounts_per_employee)::numeric, 2) AS min_accounts_per_employee,
    ROUND(MAX(accounts_per_employee)::numeric, 2) AS max_accounts_per_employee,
    ROUND(AVG(accounts_per_employee)::numeric, 2) AS avg_accounts_per_employee,
    ROUND(MIN(late_payment_rate_pct)::numeric, 2) AS min_late_payment_rate_pct,
    ROUND(MAX(late_payment_rate_pct)::numeric, 2) AS max_late_payment_rate_pct
FROM marts.mart_branch_performance;
