# Model Card — Fraud Detection

**Owner:** R Analysis Team  
**Last trained:** N/A (scaffold only; model requires live warehouse + labelled data)  
**Implementation:** `r/R/predictive.R::fit_fraud_model()` — WoE binning + logistic regression (`stats::glm`). Earlier drafts of this card claimed `tidymodels` and a GBM/XGBoost engine; neither is used.  
**Metrics written by:** `main.R::step_predict` → `output/runs/<run_key>/tables/predict_fraud_metrics.csv`

---

## Outcome definition

Binary classification: `is_fraud == 1` indicates a fraudulent transaction within the month.  
**Label date:** `month_start` — the month in which the transaction occurred.  
**Immaturity window:** Fraud labels (chargebacks) often arrive 30–60 days after the transaction month. Models must exclude the most recent immaturity window (e.g. last 2 months) to avoid artificially clean recent data. **Open:** the immaturity exclusion is not applied yet; recent months must be read as immature.

---

## Training window

- Time-ordered split in `r/R/predictive.R::time_split()`: the earliest `predictive.test_prop` (default 0.8) of rows by `month_start` train, the latest rows evaluate (`r/config/analysis.yml`).
- When the mart has no usable date column or fewer than `predictive.min_rows_for_split` rows, the pipeline still writes the metrics but labels them `validation = in_sample` — they must not be presented as out-of-time results.

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

- Model type: logistic regression on WoE-encoded features (`fit_fraud_model()`, reported as `type = "logistic"`).
- Features: all columns except `card_id`, `is_fraud` and the date column (`month_start` / `month_opened`).
- Scoring: `predict_risk_scores()` returns the positive-class probability.
- Optional upgrade path: gradient boosting would need `xgboost` pinned in `renv.lock` — an explicit dependency change, not a label on a logistic model.

---

## Out-of-time metrics (mandatory)

Written today by `binary_metrics()` on the held-out time slice:

| Metric | Notes |
|---|---|
| `avg_precision` (PR-AUC) | Must exceed `base_rate`; no accuracy/ROC-AUC headline |
| `precision_at_k` | Top-`k`, `k = predictive.alert_budget` (default 10) |
| `recall_at_k` | Share of all held-out fraud captured in the top-`k` |
| `base_rate` | Naive baseline for the PR comparison |

**Not yet reported — required before the model is relied on:** calibration plot, an interval (bootstrap/Wilson) around each metric, immaturity-window exclusion, cost-based threshold from `cost_threshold()`.

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
- **Scaffold only:** Current implementation is WoE + logistic regression. XGBoost/GBM requires `xgboost` and class-weight tuning; isotree for novelty detection requires `isotree`.
- **No calibration yet:** Scores are ranking scores, not calibrated probabilities.

---

## Retrain trigger

- PR-AUC on out-of-time validation drops > 0.05 from last run **and** PSI on key features (amount, hour) > 0.25.
- Manual review by risk team if fraud patterns shift (e.g. new MCC codes, new card types).
- At minimum, retrain quarterly even if metrics are stable.
