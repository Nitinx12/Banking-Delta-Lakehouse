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
