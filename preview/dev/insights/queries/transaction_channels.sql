-- Transaction channel mix from marts.mart_monthly_transactions.
SELECT
    channel,
    SUM(txn_count) AS txn_count,
    ROUND(SUM(total_amount)::numeric, 2) AS total_amount,
    ROUND(
        100.0 * SUM(total_amount) / SUM(SUM(total_amount)) OVER (),
        2
    ) AS share_pct
FROM marts.mart_monthly_transactions
GROUP BY channel
ORDER BY share_pct DESC;
