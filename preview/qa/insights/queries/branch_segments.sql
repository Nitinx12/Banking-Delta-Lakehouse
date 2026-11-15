-- Branch workload and late-payment rate by region from marts.mart_branch_performance.
SELECT
    region,
    COUNT(*) AS branches,
    ROUND(AVG(accounts_per_employee)::numeric, 2) AS avg_accounts_per_employee,
    ROUND(AVG(late_payment_rate_pct)::numeric, 2) AS avg_late_rate_pct,
    ROUND(SUM(txn_amount)::numeric, 2) AS txn_amount
FROM marts.mart_branch_performance
GROUP BY region
ORDER BY SUM(txn_amount) DESC;
