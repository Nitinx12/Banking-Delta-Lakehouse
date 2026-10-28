# Fraud detection score

| | |
|---|---|
| Status | planned |
| Owner | risk-analytics |
| R module | `R/mart_card_fraud.R` (helpers only; full model pending) |
| Mart | `marts.mart_card_fraud` |
| First production run | — |

## Purpose

Rank card transactions for manual review at a fixed alert budget, minimising the expected
cost of missed fraud versus false alerts.

## Outcome definition

Label = 1 if the transaction is later confirmed fraudulent (chargeback or fraud-team
confirmation), within an immaturity window of 30 days to avoid label lag. Transactions
inside the immaturity window are excluded from evaluation, not coded as legitimate.

## Training window

Time-ordered split: train on all months except the last 3 (out-of-time test). No random
split. Never oversample before splitting.

## Features and cut-off

All features are computed from data available at authorization time. Explicitly excluded:
any post-authorization outcome flag (e.g. `blocked`, `chargeback_status`) — these encode
the label.

| Feature | Source | Cut-off |
|---|---|---|
| amount, merchant_category, channel, card_tier | `mart_card_fraud` | at authorization |
| historical fraud rate for card/merchant | derived, prior months only | strictly before current month |

## Metrics (out-of-time)

To be filled when the model is trained. Required reporting set:

| Metric | Value | Baseline | Beats baseline? |
|---|---|---|---|
| PR-AUC | — | base fraud rate | — |
| Recall at fixed alert budget | — | random ranking | — |
| Expected cost | — | alert-everything / alert-nothing | — |

ROC-AUC alone is not sufficient for this model and must not be the headline metric.

## Calibration

Required before production: calibration slope/intercept and a reliability diagram on the
out-of-time set. Uncalibrated scores must never be presented as probabilities.

## Fairness / segment checks

PR-AUC and false-positive rate by card tier, merchant category band and region. Investigate
any segment where FPR differs by more than 2× from the overall rate.

## Known limitations

- Class imbalance: accuracy is meaningless; use case weights or threshold tuning.
- Label lag: recent months look artificially clean; exclude the immaturity window.
- Leakage: `blocked` or any post-decision flag is forbidden as a feature.
- Rule overlap: evaluate per-rule precision/recall to find redundant rules.

## Retraining trigger

Monthly PR-AUC trend monitored via `psi_check()` on scores and features. Retrain when
PSI > 0.25 on any top feature, or PR-AUC drops below the prior month by more than 0.02
for two consecutive months.

## Package versions

To be pinned in `renv.lock` at training time: `tidymodels`, `yardstick`, `probably`,
`isotree` (unsupervised novelty), `vip` / `DALEX` (explainability).
