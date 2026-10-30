# Data Dictionary — Mart Tables

*Generated from `information_schema.columns` for the seven `marts.*` tables and hand-written grain/business definitions.
Every R analysis function in `R/` cites this file. Analyses written against an undocumented grain
are the #1 source of wrong numbers.*


## grain

| Mart | Grain (unique key) | Business definition |
|---|---|---|
| `mart_kpi_monthly` | `month_start` | One row per calendar month with aggregated KPIs for the whole bank. |
| `mart_monthly_transactions` | (`month_start`, `txn_type`, `channel`, `merchant_category`, `txn_direction`, `region`, `state`) | One row per transaction type/channel/geography combination per month. |
| `mart_card_fraud` | (`month_start`, `card_type`, `card_category`, `card_tier`, `merchant_category`) | One row per card-type × merchant-category combination per month. |
| `mart_support_performance` | (`month_opened`, `issue_type`, `status`, `customer_state`, `income_band`) | One row per issue type / status / geography per month. |
| `mart_customer_360` | `customer_key` | One row per customer with aggregated transaction and product holdings. |
| `mart_branch_performance` | `branch_key` | One row per branch with aggregated customer, account, loan, and salary data. |
| `mart_loan_portfolio` | (`loan_type`, `status`, `loan_amount_band`, `term_band`, `start_year`) | One row per loan-type/status/amount-band/term/start-year combination. |


---


## mart_kpi_monthly

| Column | Type | Nullable | Business definition |
|---|---|---|---|
| month_start | DATE | NO | First day of the calendar month |
| year | INTEGER | NO | Calendar year (e.g. 2026) |
| quarter | INTEGER | NO | Quarter of year (1-4) |
| new_customers | INTEGER | NO | Number of new customers acquired this month |
| new_accounts | INTEGER | NO | Number of new accounts opened this month |
| loans_disbursed | INTEGER | NO | Number of loans disbursed this month |
| loan_amount_disbursed | NUMERIC(18,2) | NO | Total principal disbursed this month |
| avg_interest_rate | NUMERIC(5,2) | NO | Average interest rate across all loans this month |
| loan_payment_count | INTEGER | NO | Total loan payments due this month |
| loan_collections | INTEGER | NO | Total loan collections received this month |
| interest_income | NUMERIC(18,2) | NO | Interest income recognized this month |
| late_payment_rate_pct | NUMERIC(5,2) | NO | Late payments / total payments this month |
| txn_count | BIGINT | NO | Transaction count this month |
| txn_amount | NUMERIC(18,2) | NO | Total transaction amount this month |
| transacting_accounts | INTEGER | NO | Number of accounts that had at least one transaction this month |
| avg_txn_amount | NUMERIC(18,2) | NO | Average transaction amount this month |
| card_txn_count | INTEGER | NO | Card transaction count this month |
| card_spend | NUMERIC(18,2) | NO | Total card spend amount this month |
| fraud_txn_count | INTEGER | NO | Number of fraudulent transactions flagged this month |
| fraud_amount | NUMERIC(18,2) | NO | Total fraud amount flagged this month |
| fraud_rate_pct | NUMERIC(5,2) | NO | Fraud amount / txn_amount this month |
| tickets_opened | INTEGER | NO | Number of support tickets opened this month |
| tickets_resolved | INTEGER | NO | Number of support tickets resolved this month |
| ticket_resolution_rate_pct | NUMERIC(5,2) | NO | Resolved / opened this month |
| avg_resolution_days | NUMERIC(5,2) | NO | Average resolution time in days this month |
| avg_satisfaction_score | NUMERIC(5,2) | NO | Average customer satisfaction score this month |
| cumulative_customers | INTEGER | NO | Customers acquired to date (running total) |
| cumulative_accounts | INTEGER | NO | Accounts opened to date (running total) |
| cumulative_loan_amount | NUMERIC(18,2) | NO | Total loan principal disbursed to date (running total) |
| txn_amount_mom_pct | NUMERIC(5,2) | Month-on-month percent change in txn_amount |
| card_spend_mom_pct | NUMERIC(5,2) | Month-on-month percent change in card_spend |
| loan_collections_mom_pct | NUMERIC(5,2) | Month-on-month percent change in loan_collections |
| mart_refreshed_at | TIMESTAMPTZ | YES | When this row was last refreshed from the warehouse |

**Key:** `month_start` (unique per month)


---


## mart_monthly_transactions

| Column | Type | Nullable | Business definition |
|---|---|---|---|
| month_start | DATE | NO | First day of the calendar month |
| txn_type | VARCHAR(40) | NO | Type of transaction (e.g. purchase, cash_withdrawal, transfer) |
| channel | VARCHAR(40) | NO | Channel used (e.g. online, pos, atm, mobile, phone) |
| merchant_category | VARCHAR(80) | NO | Merchant category code (MCC) |
| txn_direction | VARCHAR(20) | NO | Direction (debit, credit) |
| region | VARCHAR(100) | NO | Geographical region |
| state | VARCHAR(50) | NO | State or province |
| txn_count | BIGINT | NO | Number of transactions in this bucket |
| active_accounts | INTEGER | NO | Number of active accounts involved |
| total_amount | NUMERIC(18,2) | NO | Total transaction amount |
| avg_amount | NUMERIC(18,2) | NO | Average amount per transaction |
| min_amount | NUMERIC(18,2) | NO | Minimum transaction amount in bucket |
| max_amount | NUMERIC(18,2) | NO | Maximum transaction amount in bucket |
| mart_refreshed_at | TIMESTAMPTZ | YES | When this row was last refreshed from the warehouse |

**Key:** (`month_start`, `txn_type`, `channel`, `merchant_category`, `txn_direction`, `region`, `state`)


---


## mart_card_fraud

| Column | Type | Nullable | Business definition |
|---|---|---|---|
| month_start | DATE | NO | First day of the calendar month |
| card_type | VARCHAR(40) | NO | Type of card (e.g. credit, debit, prepaid) |
| card_category | VARCHAR(40) | NO | Card category (e.g. rewards, platinum, infinite) |
| card_tier | VARCHAR(40) | NO | Card tier (e.g. standard, gold, platinum) |
| merchant_category | VARCHAR(80) | NO | Merchant category (MCC) |
| txn_count | BIGINT | NO | Number of transactions this month |
| active_cards | INTEGER | NO | Number of active cards in this bucket |
| total_amount | NUMERIC(18,2) | NO | Total transaction amount |
| avg_txn_amount | NUMERIC(18,2) | NO | Average transaction amount |
| fraud_txn_count | INTEGER | NO | Number of fraudulent transactions |
| fraud_amount | NUMERIC(18,2) | NO | Total fraud amount |
| fraud_rate_pct | NUMERIC(5,2) | NO | Fraud rate = fraud_amount / total_amount |
| mart_refreshed_at | TIMESTAMPTZ | YES | When this row was last refreshed from the warehouse |

**Key:** (`month_start`, `card_type`, `card_category`, `card_tier`, `merchant_category`)


---


## mart_support_performance

| Column | Type | Nullable | Business definition |
|---|---|---|---|
| month_opened | DATE | NO | Month when the support issue was opened |
| issue_type | VARCHAR(80) | NO | Type of issue (e.g. billing, technical, account) |
| status | VARCHAR(40) | NO | Resolution status (e.g. resolved, open, pending) |
| customer_state | VARCHAR(50) | NO | Customer's state or province |
| income_band | VARCHAR(40) | NO | Customer income band (e.g. <$50k, $50k-$100k, >$100k) |
| ticket_count | BIGINT | NO | Number of tickets in this bucket |
| customers_affected | INTEGER | NO | Number of unique customers affected |
| resolved_count | BIGINT | NO | Number of tickets resolved |
| resolution_rate_pct | NUMERIC(5,2) | NO | resolved_count / ticket_count |
| avg_resolution_days | NUMERIC(5,2) | NO | Average resolution time in days (resolved only) |
| max_resolution_days | INTEGER | NO | Maximum resolution time in days (resolved only) |
| avg_satisfaction_score | NUMERIC(5,2) | NO | Average satisfaction score (resolved tickets only) |
| low_satisfaction_count | INTEGER | NO | Count of tickets with satisfaction < 3 |
| mart_refreshed_at | TIMESTAMPTZ | YES | When this row was last refreshed from the warehouse |

**Key:** (`month_opened`, `issue_type`, `status`, `customer_state`, `income_band`)


---


## mart_customer_360

| Column | Type | Nullable | Business definition |
|---|---|---|---|
| customer_key | BIGINT | NO | Unique customer identifier (hashed) |
| customer_id | VARCHAR(40) | NO | Original customer ID from source systems |
| customer_name | VARCHAR(100) | NO | Customer name |
| gender | VARCHAR(20) | NO | Gender |
| age_band | VARCHAR(40) | NO | Age group (e.g. 18-25, 26-35, 36-50, 51-65, 65+) |
| city | VARCHAR(100) | NO | Customer city |
| state | VARCHAR(50) | NO | Customer state/province |
| occupation | VARCHAR(100) | NO | Occupation |
| income_band | VARCHAR(40) | NO | Personal income band |
| annual_income | NUMERIC(18,2) | NO | Annual income |
| join_date | DATE | NO | Date customer joined the bank |
| credit_score | INTEGER | NO | Current credit score |
| credit_band | VARCHAR(40) | NO | Credit band (e.g. fair, good, excellent) |
| total_accounts | INTEGER | NO | Total number of accounts held |
| active_accounts | INTEGER | NO | Number of currently active accounts |
| total_cards | INTEGER | NO | Total number of cards held |
| active_cards | INTEGER | NO | Number of currently active cards |
| total_credit_limit | NUMERIC(18,2) | NO | Total credit limit across all cards |
| total_loans | INTEGER | NO | Total number of loans |
| active_loans | INTEGER | NO | Number of currently active loans |
| total_loan_amount | NUMERIC(18,2) | NO | Total loan amount across all loans |
| loan_to_income_ratio | NUMERIC(18,2) | NO | Total_loan_amount / annual_income |
| txn_count | BIGINT | NO | Total transaction count |
| txn_amount | NUMERIC(18,2) | NO | Total transaction amount |
| last_txn_date | DATE | NO | Date of most recent transaction |
| card_txn_count | INTEGER | NO | Card transaction count |
| card_spend | NUMERIC(18,2) | NO | Total card spend amount |
| card_fraud_txn_count | INTEGER | NO | Number of card fraud transactions |
| total_tickets | INTEGER | NO | Total support tickets filed |
| resolved_tickets | INTEGER | NO | Total support tickets resolved |
| avg_resolution_days | NUMERIC(5,2) | NO | Average resolution time in days |
| avg_satisfaction_score | NUMERIC(5,2) | NO | Average satisfaction score |
| products_held | INTEGER | NO | Number of distinct products held |
| mart_refreshed_at | TIMESTAMPTZ | YES | When this row was last refreshed from the warehouse |

**Key:** `customer_key`


---


## mart_branch_performance

| Column | Type | Nullable | Business definition |
|---|---|---|---|
| branch_key | BIGINT | NO | Unique branch identifier |
| branch_id | VARCHAR(40) | NO | Branch ID from source system |
| branch_name | VARCHAR(200) | NO | Branch name |
| city | VARCHAR(100) | NO | Branch city |
| state | VARCHAR(50) | NO | Branch state/province |
| region | VARCHAR(100) | NO | Region (e.g. North, South, East, West) |
| ifsc_code | VARCHAR(20) | NO | IFSC code (branch identifier) |
| opened_year | INTEGER | NO | Year branch opened |
| branch_age_band | VARCHAR(40) | NO | Band based on years since opening (e.g. new, established, mature) |
| total_customers | INTEGER | NO | Total customers associated with branch |
| total_accounts | INTEGER | NO | Total number of accounts |
| active_accounts | INTEGER | NO | Number of currently active accounts |
| employee_count | INTEGER | NO | Number of employees at branch |
| total_salary_cost | NUMERIC(18,2) | NO | Total annual salary cost for branch employees |
| avg_salary | NUMERIC(18,2) | NO | Average employee salary |
| total_loans | INTEGER | NO | Total number of loans at branch |
| active_loans | INTEGER | NO | Number of currently active loans at branch |
| total_loan_amount | NUMERIC(18,2) | NO | Total loan amount at branch |
| avg_interest_rate | NUMERIC(5,2) | NO | Average interest rate across branch loans |
| total_loan_collected | NUMERIC(18,2) | NO | Total amount of loan collections |
| late_payment_rate_pct | NUMERIC(5,2) | NO | Late payments / total payments |
| txn_count | BIGINT | NO | Transaction count at branch |
| txn_amount | NUMERIC(18,2) | NO | Total transaction amount at branch |
| accounts_per_employee | NUMERIC(18,2) | NO | active_accounts / employee_count |
| mart_refreshed_at | TIMESTAMPTZ | YES | When this row was last refreshed from the warehouse |

**Key:** `branch_key`


---


## mart_loan_portfolio

| Column | Type | Nullable | Business definition |
|---|---|---|---|
| loan_type | VARCHAR(40) | NO | Type of loan (e.g. personal, home, business, auto, credit_card) |
| status | VARCHAR(40) | NO | Current status (e.g. current, late, default, foreclosure) |
| loan_amount_band | VARCHAR(40) | NO | Band of total loan amount (e.g. <$10k, $10k-$50k, $50k-$100k, >$100k) |
| term_band | VARCHAR(40) | NO | Band of term in months (e.g. <24, 24-60, 60-120, >120) |
| start_year | INTEGER | NO | Year when the loan started |
| loan_count | INTEGER | NO | Number of loans in this bucket |
| total_loan_amount | NUMERIC(18,2) | NO | Total principal amount in this bucket |
| avg_loan_amount | NUMERIC(18,2) | NO | Average loan amount in this bucket |
| avg_interest_rate | NUMERIC(5,2) | NO | Average interest rate in this bucket |
| avg_term_months | NUMERIC(5,2) | NO | Average term in months |
| payment_count | INTEGER | NO | Total payments made across all loans in bucket |
| total_paid | NUMERIC(18,2) | NO | Total amount paid (principal + interest) |
| principal_paid | NUMERIC(18,2) | NO | Total principal paid off |
| interest_paid | NUMERIC(18,2) | NO | Total interest paid |
| late_payments | INTEGER | NO | Number of late payments |
| late_payment_rate_pct | NUMERIC(5,2) | NO | late_payments / payment_count |
| estimated_outstanding_principal | NUMERIC(18,2) | NO | Estimated remaining principal |
| mart_refreshed_at | TIMESTAMPTZ | YES | When this row was last refreshed from the warehouse |

**Key:** (`loan_type`, `status`, `loan_amount_band`, `term_band`, `start_year`)


--- 

*This data dictionary is referenced by all analysis functions in `R/`. If a column name changes in the warehouse, update both `config/contracts.yml` and this file.*