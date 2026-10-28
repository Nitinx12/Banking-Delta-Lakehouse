# Customer attrition / dormancy risk

| | |
|---|---|
| Status | planned |
| Owner | customer-analytics |
| R module | `R/mart_customer_360.R` (helpers only; full model pending) |
| Mart | `marts.mart_customer_360` |
| First production run | — |

## Purpose

Score active customers for the risk of becoming dormant (no transaction for N days) or
closing their primary relationship, to target retention outreach.

## Outcome definition

Label = 1 if the customer has **no recorded transaction** for 90 consecutive days during
the observation window, starting from the feature cut-off date. Customers who were already
dormant at the cut-off are excluded from training. The 90-day window is fixed in
`config/analysis.yml` and must not be tuned on the test set.

## Training window

Time-ordered split: features at month T, label window (T, T+3]. Train on T ≤ T0, validate
on T > T0. No features from after the label window start.

## Features and cut-off

All features are computed strictly before the label window opens.

| Feature | Source | Cut-off |
|---|---|---|
| txn_count, card_spend, last_txn_date (recency) | `mart_customer_360` | at month T |
| total_accounts, products_held | `mart_customer_360` | at month T |
| total_tickets, avg_satisfaction_score | `mart_customer_360` | at month T |
| rfm scores | derived via `rfm_score()` | at month T |

Forbidden: any feature derived from activity inside the label window.

## Metrics (out-of-time)

| Metric | Value | Baseline | Beats baseline? |
|---|---|---|---|
| AUC | — | base dormancy rate | — |
| Precision@k (top 5% scored) | — | random | — |
| Lift in top decile | — | 1.0 | — |

## Calibration

Required: calibration plot on the out-of-time set. Retention capacity planning uses
calibrated probabilities, not raw scores.

## Fairness / segment checks

False-negative rate and score distribution by income band, age band, city tier and
occupation. A model that systematically under-scores a segment will systematically
under-serve it.

## Known limitations

- Seasonality: dormancy risk is higher in certain months; include calendar controls.
- Product mix: multi-product customers are structurally less likely to go dormant — the
  model may simply rediscover product holding. Evaluate an incremental model with
  product-mix features removed.
- PII: this mart is the most identifier-heavy; hash IDs before any export.

## Retraining trigger

Quarterly, or when segment-level PSI on top features exceeds 0.25, or when the label
definition changes.

## Package versions

To be pinned in `renv.lock` at training time: `tidymodels`, `probably`, `tidyclust`
(for the companion segmentation), `ineq` (for concentration of at-risk balances).
