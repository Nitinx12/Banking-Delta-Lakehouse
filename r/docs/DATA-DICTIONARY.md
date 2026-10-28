# Data dictionary (generated)

## mart_monthly_transactions

| column | type | nullable |
|---|---|---|
| month_start | date | YES |
| txn_type | character varying | YES |
| channel | character varying | YES |
| merchant_category | character varying | YES |
| txn_direction | character varying | YES |
| region | character varying | YES |
| state | character varying | YES |
| txn_count | bigint | YES |
| active_accounts | bigint | YES |
| total_amount | numeric | YES |
| avg_amount | numeric | YES |
| min_amount | numeric | YES |
| max_amount | numeric | YES |
| mart_refreshed_at | timestamp with time zone | YES |

## mart_kpi_monthly

| column | type | nullable |
|---|---|---|
| month_start | date | YES |
| year | integer | YES |
| quarter | integer | YES |
| new_customers | bigint | YES |
| new_accounts | bigint | YES |
| loans_disbursed | bigint | YES |
| loan_amount_disbursed | numeric | YES |
| avg_interest_rate | numeric | YES |
| loan_payment_count | bigint | YES |
| loan_collections | numeric | YES |
| interest_income | numeric | YES |
| late_payment_rate_pct | numeric | YES |
| txn_count | bigint | YES |
| txn_amount | numeric | YES |
| transacting_accounts | bigint | YES |
| avg_txn_amount | numeric | YES |
| card_txn_count | bigint | YES |
| card_spend | numeric | YES |
| fraud_txn_count | bigint | YES |
| fraud_amount | numeric | YES |
| fraud_rate_pct | numeric | YES |
| tickets_opened | bigint | YES |
| tickets_resolved | bigint | YES |
| ticket_resolution_rate_pct | numeric | YES |
| avg_resolution_days | numeric | YES |
| avg_satisfaction_score | numeric | YES |
| cumulative_customers | numeric | YES |
| cumulative_accounts | numeric | YES |
| cumulative_loan_amount | numeric | YES |
| txn_amount_mom_pct | numeric | YES |
| card_spend_mom_pct | numeric | YES |
| loan_collections_mom_pct | numeric | YES |
| mart_refreshed_at | timestamp with time zone | YES |

## mart_card_fraud

| column | type | nullable |
|---|---|---|
| month_start | date | YES |
| card_type | character varying | YES |
| card_category | character varying | YES |
| card_tier | character varying | YES |
| merchant_category | character varying | YES |
| txn_count | bigint | YES |
| active_cards | bigint | YES |
| total_amount | numeric | YES |
| avg_txn_amount | numeric | YES |
| fraud_txn_count | bigint | YES |
| fraud_amount | numeric | YES |
| fraud_rate_pct | numeric | YES |
| mart_refreshed_at | timestamp with time zone | YES |

## mart_support_performance

| column | type | nullable |
|---|---|---|
| month_opened | date | YES |
| issue_type | character varying | YES |
| status | character varying | YES |
| customer_state | character varying | YES |
| income_band | character varying | YES |
| ticket_count | bigint | YES |
| customers_affected | bigint | YES |
| resolved_count | bigint | YES |
| resolution_rate_pct | numeric | YES |
| avg_resolution_days | numeric | YES |
| max_resolution_days | integer | YES |
| avg_satisfaction_score | numeric | YES |
| low_satisfaction_count | bigint | YES |
| mart_refreshed_at | timestamp with time zone | YES |

## mart_customer_360

| column | type | nullable |
|---|---|---|
| customer_key | integer | YES |
| customer_id | integer | YES |
| customer_name | character varying | YES |
| gender | character varying | YES |
| age_band | character varying | YES |
| city | character varying | YES |
| state | character varying | YES |
| occupation | character varying | YES |
| income_band | character varying | YES |
| annual_income | numeric | YES |
| join_date | date | YES |
| credit_score | integer | YES |
| credit_band | character varying | YES |
| total_accounts | bigint | YES |
| active_accounts | bigint | YES |
| total_cards | bigint | YES |
| active_cards | bigint | YES |
| total_credit_limit | numeric | YES |
| total_loans | bigint | YES |
| active_loans | bigint | YES |
| total_loan_amount | numeric | YES |
| loan_to_income_ratio | numeric | YES |
| txn_count | bigint | YES |
| txn_amount | numeric | YES |
| last_txn_date | date | YES |
| card_txn_count | bigint | YES |
| card_spend | numeric | YES |
| card_fraud_txn_count | bigint | YES |
| total_tickets | bigint | YES |
| resolved_tickets | bigint | YES |
| avg_resolution_days | numeric | YES |
| avg_satisfaction_score | numeric | YES |
| products_held | integer | YES |
| mart_refreshed_at | timestamp with time zone | YES |

## mart_branch_performance

| column | type | nullable |
|---|---|---|
| branch_key | integer | YES |
| branch_id | integer | YES |
| branch_name | character varying | YES |
| city | character varying | YES |
| state | character varying | YES |
| region | character varying | YES |
| ifsc_code | character varying | YES |
| opened_year | integer | YES |
| branch_age_band | character varying | YES |
| total_customers | bigint | YES |
| total_accounts | bigint | YES |
| active_accounts | bigint | YES |
| employee_count | bigint | YES |
| total_salary_cost | numeric | YES |
| avg_salary | numeric | YES |
| total_loans | bigint | YES |
| active_loans | bigint | YES |
| total_loan_amount | numeric | YES |
| avg_interest_rate | numeric | YES |
| total_loan_collected | numeric | YES |
| late_payment_rate_pct | numeric | YES |
| txn_count | bigint | YES |
| txn_amount | numeric | YES |
| accounts_per_employee | numeric | YES |
| mart_refreshed_at | timestamp with time zone | YES |

## mart_loan_portfolio

| column | type | nullable |
|---|---|---|
| loan_type | character varying | YES |
| status | character varying | YES |
| loan_amount_band | character varying | YES |
| term_band | character varying | YES |
| start_year | integer | YES |
| loan_count | bigint | YES |
| total_loan_amount | numeric | YES |
| avg_loan_amount | numeric | YES |
| avg_interest_rate | numeric | YES |
| avg_term_months | numeric | YES |
| payment_count | numeric | YES |
| total_paid | numeric | YES |
| principal_paid | numeric | YES |
| interest_paid | numeric | YES |
| late_payments | numeric | YES |
| late_payment_rate_pct | numeric | YES |
| estimated_outstanding_principal | numeric | YES |
| mart_refreshed_at | timestamp with time zone | YES |


