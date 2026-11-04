# Business insights

Index of the business questions answered by the `marts` schema. Each finding links to a
detail file with the exact query and chart.

## About the data

The underlying rows are CSV snapshots of the ten source tables
(`contracts/registry.json`: 5 MySQL, 2 MongoDB, 3 Databricks `public`) shipped
under `data/raw/` and exported from the live sources by
`scripts/export_raw_csv.py`; a clone loads them with `make load-raw-csv`.
See the README's "About the data" section for the full description.

- **Origin: unverified.** No generator or seed script exists anywhere in this
  repository or its git history, so the original source of the rows cannot be
  determined from the repo. TODO(owner): confirm whether the data was generated,
  taken from a public dataset, or is real.
- **Looks generated.** The shipped CSVs show sequential integer keys,
  `customerN@mailbank.com` emails and branch names like `Pune Branch 1` —
  patterns typical of generated data (observed in the files, not proof).
- **Not a benchmark.** The fraud rate (0.499%), late-payment rate (12.01%) and
  value concentration (22.55% in the top 10% of customers) are properties of
  this dataset only, not real-world banking figures. Treat every finding below
  as a demonstration of analytical method on synthetic-looking data, not as a
  finding about any real bank.

## Insights

| Question | Finding | Source mart | Detail |
| --- | --- | --- | --- |
| Is transaction value concentrated in a few customers? | Top 10% of active customers hold 22.55% of transaction value (mild concentration, since an even split would be 10%). | `marts.mart_customer_360` | [01-customers.md](insights/01-customers.md) |
| How often are loan payments late? | 12.01% of 600,005 loan payments are late. | `marts.mart_loan_portfolio` | [02-loans.md](insights/02-loans.md) |
| How much fraud is in card spend? | 0.499% of 3,005,000 card transactions (fraud amount: 28,608,185.59). | `marts.mart_card_fraud` | [03-card-fraud.md](insights/03-card-fraud.md) |
| Is transaction value concentrated in a few channels? | Six channels split value almost evenly (16.62% to 16.70%). | `marts.mart_monthly_transactions` | [04-transactions.md](insights/04-transactions.md) |
| Are branches evenly loaded? | Accounts per employee range from 27.55 to 211.33 across 151 branches. | `marts.mart_branch_performance` | [05-branches.md](insights/05-branches.md) |
| Is customer support meeting its SLA? | 79.67% of 25,300 tickets resolved; 39.95% scored 2 or below. | `marts.mart_support_performance` | [06-support.md](insights/06-support.md) |

## Segment views

Each result is reproducible with the linked SQL against `banking_delta`.

| Domain | Segment result | So what | SQL |
| --- | --- | --- | --- |
| Customers | Upper-Mid (36.12%) and High (32.88%) income bands hold 69.00% of transaction value from 32,786 of 47,640 active customers; average value is flat at 250,807-255,284 across every band. | Target the value decile, not the income tier: average customer value barely moves by income, so income-based offers would over-serve low-value customers in high bands. | [customer_segments.sql](insights/queries/customer_segments.sql) |
| Loans | Late-payment rate is flat by loan size: 11.88% (<1L) to 12.04% (1-5L), a 0.16pp spread; loan types span 11.85-12.19%. | Run reminders and collections across the whole book; there is no small-ticket or large-ticket segment to prioritise. | [loan_segments.sql](insights/queries/loan_segments.sql) |
| Card fraud | Fraud rate is 0.479% (Platinum) to 0.507% (Classic), a 0.028pp spread; Debit cards (tier N/A) carry the largest fraud amount (15,673,144.60). | Tier-based blocking would miss most fraud; keep velocity and amount rules running on all tiers, especially Debit. | [card_fraud_segments.sql](insights/queries/card_fraud_segments.sql) |
| Transactions | Value is 26.76% North, 24.15% South, 23.29% West, 15.92% Central, 9.88% East - a 2.7x North-to-East spread, while the six channels stay within 0.08pp. | Set capacity, pricing and marketing by region; channel mix is too even to justify shifting traffic for share reasons. | [transaction_segments.sql](insights/queries/transaction_segments.sql) |
| Branches | West branches carry the highest load (65.38 accounts per employee) against North (53.11); regional late-payment rates stay within 11.96-12.14%. | Rebalance staff toward West and Central offices; do not build region-specific collections playbooks from a 0.18pp late-rate spread. | [branch_segments.sql](insights/queries/branch_segments.sql) |
| Support | Resolution is 78.61% for Account Statement to 81.15% for Net Banking Issue; satisfaction stays 2.97-3.04 across issue types, and the Low income band resolves worst (78.36%). | Fix the statement, KYC and loan-query workflows first, and investigate why satisfaction does not move with resolution - the driver looks systemic, not issue-specific. | [support_segments.sql](insights/queries/support_segments.sql) |
