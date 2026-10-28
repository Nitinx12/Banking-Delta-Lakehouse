# Probability of default scorecard

| | |
|---|---|
| Status | planned |
| Owner | credit-risk |
| R module | `R/mart_loan_portfolio.R` (helpers only; full model pending) |
| Mart | `marts.mart_loan_portfolio` |
| First production run | — |

## Purpose

Estimate 12-month probability of default for retail loan applications and for the existing
portfolio, feeding expected-loss calculation and pricing.

## Outcome definition

Label = 1 if the loan reaches 90+ days past due within 12 months of origination, or is
written off, whichever comes first. Open loans with less than 12 months of history are
right-censored, not coded as good. Prepayments are competing risks and are censored at
prepayment date.

## Training window

Out-of-time validation is mandatory: train on cohorts origination ≤ T-6 months, validate
on cohorts origination in (T-6, T]. Never random-split loans that share an origination
month.

## Features and cut-off

All features are computed from application data and bureau data available at
origination time. Explicitly excluded: any post-origination payment behaviour
(payment_count, late_payments after month 0).

| Feature | Source | Cut-off |
|---|---|---|
| loan_amount_band, term_band, avg_interest_rate | `mart_loan_portfolio` | at application |
| income_band, credit_band, tenure | `mart_customer_360` | at application |

## Metrics (out-of-time)

| Metric | Value | Baseline | Beats baseline? |
|---|---|---|---|
| AUC | — | base default rate (constant score) | — |
| KS | — | — | — |
| Gini | — | — | — |
| Calibration intercept / slope | — | 0 / 1 | — |

A model is only reported if it beats the documented naive baseline on the out-of-time set.

## Calibration

Required: `probably::cal_plot_breaks` on the out-of-time set. An uncalibrated score must
never be presented as a probability or multiplied into expected loss.

## Fairness / segment checks

Default-rate calibration and AUC by income band, occupation and region. Document any
segment where calibration error exceeds the overall error by more than 50%.

## Known limitations

- Right censoring: open loans are not "good".
- Vintage effects: macro conditions differ across origination cohorts.
- LGD/EAD are not modelled here — expected loss is indicative until those inputs exist.

## Retraining trigger

Semi-annual, or when out-of-time AUC drops by more than 0.03 versus the champion, or when
a new vintage completes 6 months of performance history.

## Package versions

To be pinned in `renv.lock` at training time: `scorecard` (WoE/IV), `glmnet`, `tidymodels`,
`probably`, `survival` (for the time-to-default companion analysis).
