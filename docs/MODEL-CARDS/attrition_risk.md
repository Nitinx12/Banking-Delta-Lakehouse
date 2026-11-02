# Model Card — Attrition Risk

**Owner:** R Analysis Team  
**Last trained:** N/A (scaffold only; model requires live warehouse + labelled data)  
**Implementation:** `r/R/predictive.R::fit_attrition_model()` — WoE binning + logistic regression (`stats::glm`). `tidymodels`/`parsnip` are **not** used.  
**Metrics written by:** `main.R::step_predict` → `output/runs/<run_key>/tables/predict_attrition_metrics.csv`

---

## Outcome definition

Binary classification: `is_attrited == 1` indicates the customer had no activity for at least N days (e.g. 90 days) and subsequently closed or became inactive.  
**Label definition:** `is_attrited = 1` if `max(observation_window) - last_txn_date > 90` days (configurable).  
**Label date:** `last_txn_date` — the most recent transaction date observed.

**Immaturity window:** As with fraud, attrition labels may lag. Exclude the most recent 30–60 days of data to avoid mislabeling recently active customers.

---

## Training window

- Data filtered to customers with `last_txn_date <= label_date - 60` (exclude immaturity window).
- Time-ordered split: earlier months used for training, most recent month for out-of-time validation.

---

## Features and feature cut-off

| Feature group | Example columns | Cut-off vs label |
|---|---|---|
| Transaction features | `txn_count`, `txn_amount`, `card_txn_count` | Must be observed up to label date; no future information |
| Product features | `products_held`, `total_cards`, `total_loans` | Static snapshot at label date |
| Customer attributes | `age_band`, `income_band`, `credit_band` | Fixed at observation time |

**Feature cut-off:** All features must be available at the label date. No encoding of the `is_attrited` outcome after the last transaction date is permitted.

---

## Model

- Model type: logistic regression on WoE-encoded features (`fit_attrition_model()`, reported as `type = "logistic"`).
- Features: all columns except `customer_id`, `is_attrited` and the date column (`month_start` / `month_opened`).

---

## Out-of-time metrics (mandatory)

Written today by `binary_metrics()` on the held-out time slice (`time_split()`, earliest `predictive.test_prop` of rows by date train):

| Metric | Notes |
|---|---|
| `avg_precision` | Ranking quality against `base_rate` |
| `precision_at_k` / `recall_at_k` | `k = predictive.alert_budget` |
| `base_rate` | Naive baseline |
| `validation` + `cutoff` | `oos_time_ordered` when the split ran, otherwise `in_sample` |

**Not yet reported — required before the model is relied on:** AUROC with a bootstrap interval, calibration plot, label immaturity exclusion, sensitivity of the inactivity window (30/60/90 days).

| Metric | Target / threshold | Notes |
|---|---|---|
| AUC (AUROC) | Must exceed naive baseline (prevalence-driven) | Report with 95% CI |
| Precision at top 5% | Report | Business-relevant for alert budget |
| Calibration | `probably::cal_plot_breaks()` — ideally calibrated | Probabilities should be calibrated |
| Out-of-time AUC | Compute AUC on *latest month* only | Must beat naive baseline on out-of-time set |

**Naive baseline:** Predict the overall attrition rate for every customer. AUC of naive reflects the baseline attrition prevalence. Model must beat this on the out-of-time set.

---

## Fairness / segment checks

- Compute attrition rate per `age_band`, `income_band`, `credit_band` after deployment.
- Report exposure (number of customers) per segment.
- Ensure no segment is systematically disadvantaged without documented reason.

---

## Known limitations

- **Label definition sensitivity:** Attrition depends on the chosen inactivity window (30/60/90 days). Sensitivity analysis recommended.
- **Class imbalance:** Attrition rates typically 5–15%. Metrics reflect this.
- **Scaffold only:** Current implementation uses logistic regression. Advanced models (gradient boosting, random forests) may improve discrimination but require `xgboost` or `ranger` packages.
- **Temporal drift:** Customer behavior changes; retrain required when out-of-time AUC drops.

---

## Retrain trigger

- Out-of-time AUC drops > 0.03 from last run **and** PSI on key features (txn_amount, products_held) > 0.25.
- New data becomes available (e.g. monthly update).
- At minimum, retrain quarterly even if metrics are stable.