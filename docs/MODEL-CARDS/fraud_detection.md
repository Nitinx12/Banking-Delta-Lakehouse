# Model Card — Fraud Detection

**Owner:** R Analysis Team  
**Last trained:** N/A (scaffold only; model requires live warehouse + labelled data)  
**Package version:** `tidymodels` (placeholder `glm` engine); `xgboost` not yet pinned in `renv.lock`

---

## Outcome definition

Binary classification: `is_fraud == 1` indicates a fraudulent transaction within the month.  
**Label date:** `month_start` — the month in which the transaction occurred.  
**Immaturity window:** Fraud labels (chargebacks) often arrive 30–60 days after the transaction month. Models must exclude the most recentimmaturity window (e.g. last 2 months) to avoid artificially clean recent data.

---

## Training window

- Data is filtered to `month_start <= label_date - 60` (exclude last 2 months of immaturity).
- Time-ordered split: all earlier months used for training, most recent month used for out-of-time validation.

---

## Features and feature cut-off

| Feature group | Example columns | Cut-off vs label |
|---|---|---|
| Transaction features | `txn_amount`, `hour`, `day_of_week` | Must not encode the label outcome (e.g. no "blocked" flag) |
| Card features | `card_type`, `card_tier`, `card_category` | Fixed per card; no leakage from future months |
| Merchant features | `merchant_category` | Static attribute; no post-outcome encoding |

**Feature cut-off:** All features must be available at or before `month_start`. No encoding of the `is_fraud` outcome after the transaction date is permitted.

---

## Model

Scaffold uses a **logistic regression** with `parsnip`/`glm` engine (placeholder for GBM or XGBoost).

- Model type: `logistic_reg() %>% set_engine("glm")`
- Features: all columns except `card_id`, `is_fraud`, `month_start`
- Time split: `initial_time_split()` with `prop = 0.8` on the time-ordered data

---

## Out-of-time metrics (mandatory)

| Metric | Target / threshold | Notes |
|---|---|---|
| PR-AUC | Must exceed naive baseline (no-skill = prev_rate) | Report with 95% CI |
| Recall at alert budget | E.g. recall at top 1% of scored transactions | Business-defined alert budget |
| Precision at top 10% | Report alongside recall | |
| Calibration | `probably::cal_plot_breaks()` — ideally | Probabilities should be calibrated; uncalibrated scores must not be presented as probabilities |

**Naive baseline:** Predict the overall fraud rate for every transaction. PR-AUC of naive = prevalence. Model must beat this on the out-of-time set.

---

## Fairness / segment checks

- Compute fraud rate per `card_type` and `card_tier` after model deployment.
- Ensure no segment has dramatically higher false-alert rates without business justification.
- Document any known disparities.

---

## Known limitations

- **Class imbalance:** Fraud typically < 5% of transactions. Metric choice (PR-AUC, recall@budget) reflects this.
- **Label delay:** Chargebacks arrive after the transaction month; recent months look artificially clean.
- **Feature constraints:** Must not use any feature that encodes the outcome after the transaction date.
- **Scaffold only:** Current implementation uses logistic regression with placeholder engine. XGBoost/GBM requires `xgboost` package and class-weight tuning.

---

## Retrain trigger

- PR-AUC on out-of-time validation drops > 0.05 from last run **and** PSI on key features (amount, hour) > 0.25.
- Manual review by risk team if fraud patterns shift (e.g. new MCC codes, new card types).
- At minimum, retrain quarterly even if metrics are stable.


---

# Model Card — Probability of Default (PD) Scorecard

**Owner:** R Analysis Team  
**Last trained:** N/A (scaffold only; model requires live warehouse + labelled data)  
**Package version:** `tidymodels` (`rsample`, `recipes`, `parsnip`); `scorecard` not yet pinned in `renv.lock`

---

## Outcome definition

Binary classification: `is_default == 1` indicates the loan went into default within the observation window.  
**Label date:** `start_year` + origination date — the cohort year when the loan was originated.  
**Censoring:** Open loans (no default observed) are right-censored in survival analysis; PD scorecard uses a fixed observation window (e.g. 24 months after origination).

---

## Training window

- Data filtered to loans with `start_year <= 2023` (originated at least 24 months ago to have sufficient default events).
- Time-ordered split: earlier cohorts used for training, latest cohort(s) used for out-of-time validation.

---

## Features and feature cut-off

| Feature | Example | Cut-off vs label |
|---|---|---|
| Origination features | `loan_amount`, `term_months`, `interest_rate` | Must be known at origination; no post-originating information |
| Borrower features | `credit_score`, `income_band`, `loan_to_income_ratio` | Static at origination; no future information |
| Loan purpose | `loan_type` | Fixed at origination |

**Feature cut-off:** All features must be available at loan origination (`start_year`). No encoding of the `is_default` outcome after origination is permitted.

---

## Model

Scaffold uses **logistic regression** with WoE binning (placeholder; production would use `scorecard` package).

- Model type: `logistic_reg() %>% set_engine("glm")`
- Feature preprocessing: `step_normalize(all_numeric_predictors())` (scaffold only; production uses WoE `step_woe()`)
- Features: all columns except `loan_id`, `is_default`, `start_year`

---

## Out-of-time metrics (mandatory)

| Metric | Target / threshold | Notes |
|---|---|---|
| AUC (AUROC) | Must exceed naive baseline (0.5) | Report with 95% CI |
| KS statistic | Report; no absolute threshold | Discrimination only |
| Gini | `2 * AUC - 1` | Report for consistency |
| Calibration | `probably::cal_plot_breaks()` — ideally calibrated | Probabilities should be calibrated; uncalibrated scores must not be presented as probabilities |
| Out-of-time ROC | Compute AUC on *latest cohort* only (not training cohort) | Must beat naive baseline on out-of-time set |

**Naive baseline:** Predict the overall default rate for every loan. AUC of naive = 0.5 (if classes are balanced) or prevalence-driven. Model must beat this on the out-of-time set.

---

## Fairness / segment checks

- Compute default rate per `loan_type` and `credit_band` after deployment.
- Ensure no segment has systematically higher default rates without documented reason.
- Report exposure (number of loans) per segment.

---

## Known limitations

- **Right-censoring:** Open loans are censored, not "good". Survival methods should complement the PD scorecard.
- **Class imbalance:** Default rates typically 2–5%. Metrics reflect this (AUC, not accuracy).
- **Scaffold only:** Current implementation uses logistic regression without full WoE binning. Production scorecard requires IV/IV binning and monotonicity constraints.
- **Temporal drift:** PD models decay as economic conditions change; retrain required when out-of-time AUC drops.

---

## Retrain trigger

- Out-of-time AUC drops > 0.03 from last run **and** PSI on key features (credit_score, loan_amount) > 0.25.
- New cohort of loans becomes available (e.g. annual origination surge).
- At minimum, retrain yearly even if metrics are stable.


---

# Model Card — Attrition Risk

**Owner:** R Analysis Team  
**Last trained:** N/A (scaffold only; model requires live warehouse + labelled data)  
**Package version:** `tidymodels` (`rsample`, `recipes`, `parsnip`); `parsnip` with `glm` engine

---

## Outcome definition

Binary classification: `is_attrited == 1` indicates the customer had no activity for at least `N` days (e.g. 90 days) and subsequently closed or became inactive.  
**Label definition:** `is_attrited = 1` if `max(datum_date) - last_txn_date > 90` days (configurable).  
**Label date:** `month_start` or `last_txn_date` — the most recent transaction date observed.

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