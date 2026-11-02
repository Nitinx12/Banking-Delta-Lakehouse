### Do a small group of customers drive most transaction value?

**Business question:** Head of Retail Banking / CRM lead would ask this to decide where retention and cross-sell budget goes.

**Data used:** `marts.mart_customer_360` (grain: one row per customer)

**Finding:** Among customers with transaction activity, the top 10% by transaction value account for 22.55% of total transaction value (2,727,440,949.25 of 12,096,774,249.05). ![chart](../../assets/insights/01-customers.png)

**So what:** Prioritise retention, fee-waiver and cross-sell offers for the top decile, and run a reactivation journey for the 12,361 customers with no transaction activity.

**Reproduce:** `docs/insights/queries/customer_concentration.sql` with `psql -U postgres -d banking_delta -f docs/insights/queries/customer_concentration.sql`
