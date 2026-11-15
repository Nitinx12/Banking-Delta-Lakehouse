-- Customer value by income band from marts.mart_customer_360.
SELECT
    income_band,
    COUNT(*) AS customers,
    ROUND(SUM(txn_amount)::numeric, 2) AS txn_amount,
    ROUND(100.0 * SUM(txn_amount) / SUM(SUM(txn_amount)) OVER (), 2) AS value_share_pct,
    ROUND(AVG(txn_amount)::numeric, 2) AS avg_txn_amount,
    ROUND(AVG(products_held)::numeric, 2) AS avg_products
FROM marts.mart_customer_360
WHERE txn_amount IS NOT NULL
  AND txn_amount > 0
GROUP BY income_band
ORDER BY txn_amount DESC;
