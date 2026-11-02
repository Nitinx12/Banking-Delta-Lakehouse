# Model Card — PD Scorecard

**Owner:** R Analysis Team  
**Last trained:** N/A (scaffold only; model requires live warehouse + labelled data)  
**Implementation:** `r/R/predictive.R::fit_pd_scorecard()` — WoE binning + logistic regression (`stats::glm`). `tidymodels` and `scorecard` are **not** used and are not pinned in `renv.lock`.  
**Metrics written by:** `main.R::step_predict` → `output/runs/<run_key>/tables/predict_pd_metrics.csv`

---

## Outcome definition

Binary classification: `is_default == 1` indicates the loan went into default within the observation window (typically 24 months from origination).  
**Label date:** `start_year` + origination date — the cohort year when the loan was originated.  
**Censoring policy:** Open loans (no default observed within window) are right-censored. The PD scorecard models probability of default within the fixed window; censored loans contribute to the "at-risk" set but are not counted as events if they default after the window.

---

## Training window

- Data filtered to loans with `start_year <= 2021` (originated at least 36 months ago to have sufficient default events for model training).
- Time-ordered split: earlier cohorts used for training, latest 1–2 cohorts used for out-of-time validation.

---

## Features and feature cut-off

| Feature | Example | Cut-off vs label |
|---|---|---|
| Origination attributes | `loan_amount`, `term_months`, `interest_rate` | Must be known at origination; no post-originating information |
| Borrower attributes | `credit_score`, `annual_income`, `loan_to_income_ratio` | Static at origination; no future information |
| Loan purpose | `loan_type` | Fixed at origination |

**Feature cut-off:** All features must be available at loan origination (`start_year`). No encoding of the `is_default` outcome after origination is permitted.

---

## Model

- Model type: logistic regression on WoE-encoded features (`fit_pd_scorecard()`, reported as `type = "logistic"`).
- Binning: quantile bins for numeric features, level bins for categoricals, each converted to weight of evidence; IV per feature is returned in `$iv`.
- Features: all columns except `loan_id`, `is_default` and the date column (`month_start` / `month_opened`).
- Complementary survival view: `r/R/mart_loan_portfolio.R::cox_fit()` fits a Cox model on `months_on_book` × `is_default` when the mart carries exposure time, writing `predict_pd_survival.csv` (hazard ratios + concordance).

---

## Out-of-time metrics (mandatory)

Written today by `binary_metrics()` on the held-out time slice (`time_split()`, earliest `predictive.test_prop` of rows by date train):

| Metric | Notes |
|---|---|
| `avg_precision` | Ranking quality against `base_rate` |
| `precision_at_k` / `recall_at_k` | `k = predictive.alert_budget` |
| `base_rate` | Naive baseline |
| `validation` + `cutoff` | `oos_time_ordered` when the split ran, otherwise `in_sample` — never read in-sample numbers as out-of-time |

**Not yet reported — required before the model is relied on:** AUROC/KS with a bootstrap interval, calibration (`probably::cal_plot_breaks()`), out-of-time AUC on the latest cohort, an explicit cohort filter (`start_year <= ...`).

| Metric | Target / threshold | Notes |
|---|---|---|
| AUC (AUROC) | Must exceed naive baseline (0.5) | Report with 95% CI from bootstrap |
| KS statistic | Report; no absolute threshold | Discrimination measure |
| Gini | `2 * AUC - 1` | Report for consistency |
| Calibration | `probably::cal_plot_breaks()` — ideally calibrated | Probabilities should be calibrated; uncalibrated scores must not be presented as probabilities |
| Brier score | Report | Mean squared error of predicted probabilities vs. observed default |
| Out-of-time AUC | Compute AUC on *latest cohort* only | Must beat naive baseline on out-of-time set |

**Naive baseline:** Predict the overall default rate for every loan. AUC of naive = 0.5 (if classes are balanced) or prevalence-driven. Model must beat this on the out-of-time set.

---

## Fairness / segment checks

- Compute default rate per `loan_type`, `credit_band`, and `customer_state` after deployment.
- Report exposure (number of loans) per segment.
- Ensure no segment has systematically higher default rates without documented reason.

---

## Known limitations

- **Right-censoring:** Open loans are censored, not "good". The scorecard models probability of default within the window; it does not predict ultimate default.
- **Class imbalance:** Default rates typically 2–5%. Metrics (AUC, not accuracy) reflect this.
- **Scaffold only:** WoE binning + logistic regression are implemented and tested; IV filtering (keep only features with IV > 0.1), monotonicity constraints and calibration are not.
- **Temporal drift:** PD models decay as economic conditions change (unemployment, interest rates); retrain required when out-of-time AUC drops.
- **Feature interpretability:** Without WoE, individual prediction interpretation is limited. WoE coefficients map directly to log-odds change per unit.

---

## Retrain trigger

- Out-of-time AUC drops > 0.03 from last run **and** PSI on key features (credit_score, loan_amount) > 0.25.
- New cohort of loans becomes available (e.g. annual origination surge).
- At minimum, retrain yearly even if metrics are stable.