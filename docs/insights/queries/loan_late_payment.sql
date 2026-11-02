-- Loan late-payment rate from marts.mart_loan_portfolio.
SELECT
    COUNT(*) AS portfolio_groups,
    SUM(payment_count) AS payment_count,
    SUM(late_payments) AS late_payment_count,
    ROUND(
        100.0 * SUM(late_payments) / NULLIF(SUM(payment_count), 0),
        2
    ) AS late_payment_rate_pct,
    ROUND(SUM(total_loan_amount)::numeric, 2) AS total_loan_amount
FROM marts.mart_loan_portfolio
WHERE loan_type IS NOT NULL;
