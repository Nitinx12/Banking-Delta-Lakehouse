-- Customer value concentration from marts.mart_customer_360.
SELECT
    COUNT(*) AS customers,
    ROUND(SUM(txn_amount)::numeric, 2) AS total_txn_amount,
    ROUND(SUM(CASE WHEN decile = 1 THEN txn_amount ELSE 0 END)::numeric, 2) AS top_decile_amount,
    ROUND(
        100.0 * SUM(CASE WHEN decile = 1 THEN txn_amount ELSE 0 END)
        / NULLIF(SUM(txn_amount), 0),
        2
    ) AS top_decile_pct
FROM (
    SELECT
        txn_amount,
        NTILE(10) OVER (ORDER BY txn_amount DESC) AS decile
    FROM marts.mart_customer_360
    WHERE txn_amount IS NOT NULL
      AND txn_amount > 0
) t;
