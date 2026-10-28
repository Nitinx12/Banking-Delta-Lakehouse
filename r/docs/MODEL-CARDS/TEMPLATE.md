# Model card template

Copy this file to `docs/MODEL-CARDS/<model_name>.md` when a predictive model is added
under `R/`. One card per model. Update in the same PR that changes the model.

```markdown
# <Model name>

| | |
|---|---|
| Status | planned / in development / production / retired |
| Owner | <team or person> |
| R module | `R/<file>.R` |
| Mart | `marts.mart_<name>` |
| First production run | <YYYY-MM-DD or — |

## Purpose

One paragraph: what decision this model supports and who consumes it.

## Outcome definition

Exact label: event, window, exclusions. Example: "card fraud reported within 30 days of
authorization, excluding reversed and zero-amount transactions."

## Training window

Start and end dates of the training sample. State the time-ordered split rule.

## Features and cut-off

Table of feature name, source mart column, and the cut-off rule
(e.g. "all activity strictly before the label window start"). Explicitly state
"no post-outcome features".

## Metrics (out-of-time)

| Metric | Value | Baseline | Beats baseline? |
|---|---|---|---|
| PR-AUC / AUC / RMSE … | | seasonal-naive / base rate / logistic | yes/no |

## Calibration

Calibration plot reference or slope/intercept. Required for any probabilistic output.

## Fairness / segment checks

Performance and error rates by protected or business segments (region, income band,
card tier, branch size). State the fairness metric used.

## Known limitations

- Censoring, label lag, leakage risks, distribution-shift sensitivity.

## Retraining trigger

Explicit rule: e.g. "PSI > 0.25 on top features, or PR-AUC drops below 0.XX for two
consecutive monthly evaluations, or every 6 months."

## Package versions

Pin from `renv.lock` at training time; list key packages (e.g. `tidymodels`, `xgboost`).
```
