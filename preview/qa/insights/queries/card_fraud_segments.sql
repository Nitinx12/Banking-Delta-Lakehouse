-- Fraud rate by card tier from marts.mart_card_fraud.
SELECT
    card_tier,
    SUM(txn_count) AS txn_count,
    SUM(fraud_txn_count) AS fraud_txn_count,
    ROUND(100.0 * SUM(fraud_txn_count) / NULLIF(SUM(txn_count), 0), 3) AS fraud_rate_pct,
    ROUND(SUM(fraud_amount)::numeric, 2) AS fraud_amount
FROM marts.mart_card_fraud
GROUP BY card_tier
ORDER BY fraud_rate_pct DESC;
