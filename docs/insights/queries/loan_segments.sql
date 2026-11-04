-- Late-payment rate by loan amount band from marts.mart_loan_portfolio.
SELECT
    loan_amount_band,
    SUM(loan_count) AS loans,
    SUM(payment_count) AS payments,
    SUM(late_payments) AS late_payments,
    ROUND(100.0 * SUM(late_payments) / NULLIF(SUM(payment_count), 0), 2) AS late_rate_pct,
    ROUND(SUM(total_loan_amount)::numeric, 2) AS loan_amount
FROM marts.mart_loan_portfolio
GROUP BY loan_amount_band
ORDER BY SUM(total_loan_amount) DESC NULLS LAST;
