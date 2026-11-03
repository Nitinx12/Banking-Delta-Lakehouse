# Business insights

Index of the business questions answered by the `marts` schema. Each finding links to a
detail file with the exact query and chart.

## Insights

| Question | Finding | Source mart | Detail |
| --- | --- | --- | --- |
| Is transaction value concentrated in a few customers? | Top 10% of active customers hold 22.55% of transaction value (mild concentration, since an even split would be 10%). | `marts.mart_customer_360` | [01-customers.md](insights/01-customers.md) |
| How often are loan payments late? | 12.01% of 600,005 loan payments are late. | `marts.mart_loan_portfolio` | [02-loans.md](insights/02-loans.md) |
| How much fraud is in card spend? | 0.499% of 3,005,000 card transactions (fraud amount: 28,608,185.59). | `marts.mart_card_fraud` | [03-card-fraud.md](insights/03-card-fraud.md) |
| Is transaction value concentrated in a few channels? | Six channels split value almost evenly (16.62% to 16.70%). | `marts.mart_monthly_transactions` | [04-transactions.md](insights/04-transactions.md) |
| Are branches evenly loaded? | Accounts per employee range from 27.55 to 211.33 across 151 branches. | `marts.mart_branch_performance` | [05-branches.md](insights/05-branches.md) |
| Is customer support meeting its SLA? | 79.67% of 25,300 tickets resolved; 39.95% scored 2 or below. | `marts.mart_support_performance` | [06-support.md](insights/06-support.md) |
