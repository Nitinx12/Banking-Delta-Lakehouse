# Model Card — Attrition Risk

**Owner:** R Analysis Team  
**Last trained:** N/A (scaffold only; model requires live warehouse + labelled data)  
**Package version:** `tidymodels` (`rsample`, `recipes`, `parsnip`); `parsnip` with `glm` engine

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

Scaffold uses **logistic regression** with `parsnip`/`glm` engine.

- Model type: `logistic_reg() %>% set_engine("glm")`
- Features: all columns except `customer_id`, `is_attrited`, `month_start`

---

## Out-of-time metrics (mandatory)

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