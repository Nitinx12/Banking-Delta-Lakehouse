# Methods — Banking-Delta-Lakehouse R Analysis

*Every method documented here assumes the Tier 0 gate (`assert_marts_ready()`) has passed and themart data has been extracted and validated by `assert_contract()`. This file is the authoritative reference for assumptions, validation, and known limits. Each predictive model must also have a card in `docs/MODEL-CARDS/`.*


---


## 1. Gini coefficient

**File:** `R/stats_helpers.R::gini()`<br>
**Package:** base R only

**Purpose:** Measure of inequality (e.g. balance inequality across customers, loan amount concentration).

**Input:** Numeric vector `x` of non-negative values (sorted or unsorted; function sorts internally).

**Computation:**
1. Sort `x` ascending
2. `n <- length(x)`
3. `num <- sum((2 * seq_len(n) - n - 1) * x)`
4. `den <- n * sum(x)`
5. Return `num / den` (or `NA_real_` if `n == 0` or `den == 0`)

**Range:** `[0, 1]`, where 0 = perfect equality, 1 = perfect inequality.

**Assumptions & limits:**
- All values should be non-negative. Negative values produce meaningless results.
- Designed for continuous or discrete positive distributions.
- Not appropriate for binary classification tasks (use AUROC instead).

**Validation:** Unit test verifies `gini(rep(1, 10)) == 0`. Out-of-range inputs should be caught upstream.


---


## 2. Population Stability Index (PSI)

**File:** `R/stats_helpers.R::psi()`<br>
**Packages:** base R

**Purpose:** Detect distribution shift between a reference (expected) and current sample. Used for monitoring feature drift.

**Input:** Two numeric vectors `expected` and `actual`, and `bins` (default 10).

**Computation:**
1. Compute quantile breakpoints from `expected` at `seq(0, 1, length.out = bins + 1)`
2. Bucket both `expected` and `actual` using these breaks
3. Compute proportions `pe` and `pa` in each bucket (replace empty buckets with 1e-6)
4. `PSI = sum((pa - pe) * log(pa / pe))`

**Interpretation (standard thresholds):**
- `PSI < 0.1`: No significant shift
- `0.1 <= PSI < 0.25`: Moderate shift — investigate
- `PSI >= 0.25`: Significant shift — take action (rebuild features, re‑train model)

**Assumptions & limits:**
- Both vectors should be continuous and positive for best results with 10 bins.
- Very small samples may produce unstable PSI.
- PSI isagnostic to direction of shift — always pair with a domain review.

**Validation:** Unit test verifies `psi(x, x) < 0.01` for identical samples.


---


## 3. Variance bridge (KPI move decomposition)

**File:** `R/mart_kpi_monthly.R::kpi_variance_bridge()`<br>
**Packages:** base R

**Purpose:** Decompose a period-over-period change in a KPI into volume, rate, and interaction effects. Used in waterfall charts to explain KPI movements.

**Input:** Data frame `df` with columns:
- `value_col`: total value (e.g. `txn_amount`)
- `count_col` (optional): volume driver (e.g. `txn_count`)
- `date_col` (optional): period identifier

**When `count_col` is provided:**
- Compute rate = value / count (with `NA` when count == 0)
- Split delta between consecutive periods into:
  - `volume_effect = (n - prev_n) * prev_rate`
  - `rate_effect = prev_n * (rate - prev_rate)`
  - `interaction = (n - prev_n) * (rate - prev_rate)`
- The three effects sum exactly to `delta = value - prev_value`

**When `count_col` is NULL:** Return only `period`, `value`, `delta` (NA for first period).

**Assumptions & limits:**
- The base period is the *previous* period (row-wise lag). Not a symmetric difference.
- Designed for additive decomposition: `delta = volume + rate + interaction`.
- If `count_col` has vastly different scales across periods, rate effects may be unstable.

**Validation:** Unit tests verify:
- `delta[2] == 2` for `value = c(10, 12)`, `count = c(1, 1)`
- Volume + rate + interaction == delta (reconstruction check)
- Error on missing count column


---


## 4. KPI growth (MoM / YoY)

**File:** `R/mart_kpi_monthly.R::kpi_growth()`<br>
**Packages:** base R

**Purpose:** Compute month-on-month (MoM) and year-on-year (YoY) differences for a KPI time series.

**Input:** Data frame with `date_col` (Date) and `value_col` (numeric), plus column names as strings.

**Computation:**
- `mom = c(NA, diff(value))` — MoM change
- `yoy = c(rep(NA, 12), diff(value, lag = 12))` — YoY change (lags first 12 months)

**Assumptions & limits:**
- Requires at least 13 rows for YoY computation; first 12 YoY values are NA.
- YoY uses a lag of 12, assuming exactly monthly data with no gaps.
- Missing months break the lag pattern; fix upstream.


---


## 5. Seasonal profile (mean and share per calendar month)

**File:** `R/mart_kpi_monthly.R::kpi_seasonal_profile()`<br>
**Packages:** base R

**Purpose:** Aggregate values by calendar month (1-12) to show typical monthly pattern and each month's share of the annual total.

**Input:** Data frame with `date_col` (Date or POSIXt) and `value_col` (numeric).

**Computation:**
1. Extract month number from `date_col`: `mo <- format(date, "%m")`
2. Aggregate: mean, sum, count per month
3. `share_of_year = total_per_month / sum(all_totals)`

**Output columns:** `month` (1-12), `mean_value`, `total_value`, `n`, `share_of_year`

**Assumptions & limits:**
- Assumes data spans multiple calendar years; if only one year, `share_of_year` will be exactly 1/12 for each month.
- Gaps in the time series are not checked here — ensure completeness upstream.


---


## 6. Structural break flags (CUSUM-style)

**File:** `R/mart_kpi_monthly.R::kpi_break_flags()`<br>
**Packages:** base R

**Purpose:** Flag points in a time-ordered numeric vector where the cumulative deviation from the global mean is unusually large.

**Input:** Numeric vector `x` (time-ordered), `k` sensitivity multiplier (default 1.5).

**Computation:**
1. `g <- mean(x, na.rm = TRUE)`, `s <- sd(x, na.rm = TRUE)`
2. If `n < 6` or `s == 0`: return `rep(FALSE, n)`
3. `cum <- cumsum(x - g) / seq_len(n)`
4. Flag if `|cum| > k * s / sqrt(seq_len(n))`

**Output:** Logical vector of same length as `x`.

**Assumptions & limits:**
- Designed for moderately sized series (`n >= 6`).
- Not a replacement for formal change-point detection (`strucchange::breakpoints`) but useful as a quick screen.
- Sensitive to outliers — one extreme point can flag many subsequent rows.


---


## 7. Ratio re-computation (never average a ratio column)

**File:** `R/mart_kpi_monthly.R::kpi_recompute_ratio()`<br>
**Packages:** base R

**Purpose:** Element-wise `num / den` with safe division by zero. Enforces the rule that ratios must be recomputed from numerator and denominator, never averaged.

**Input:** Two numeric vectors `num` and `den` of equal length.

**Computation:**
- `ifelse(den == 0, NA_real_, num / den)`

**Assumptions & limits:**
- `num` and `den` must have the same length — otherwise error.
- Zero denominators produce `NA`, not `Inf` or `NaN`.


---


## 8. Wilson confidence interval for a proportion

**File:** `R/mart_card_fraud.R::wilson_interval()`<br>
**Packages:** base R (`qnorm`)

**Purpose:** Clopper-Pearson-style exact interval for a binomial proportion, with better coverage than normal approximation for small `n` or extreme `p`.

**Input:** `k` (number of successes), `n` (trials), `conf` (confidence level, default 0.95).

**Output:** `c(lower, upper)` or `c(NA, NA)` if `n == 0`.

**Formula:**
- `z <- qnorm(1 - (1 - conf) / 2)`
- `p <- k / n`
- `denom <- 1 + z^2 / n`
- `centre <- (p + z^2 / (2 * n)) / denom`
- `half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / denom`
- `c(centre - half, centre + half)`

**Assumptions & limits:**
- Intended for proportion estimation (e.g. fraud rate, SLA compliance rate).
- `n == 0` returns `c(NA, NA)`.
- Coverage is approximately nominal; for very small `n` or `p` near 0 or 1, the interval may be wide.


---


## 9. Cost-threshold selection

**File:** `R/mart_card_fraud.R::cost_threshold()`<br>
**Packages:** base R

**Purpose:** Choose a probability threshold that minimises expected cost, given asymmetric costs of false negatives and false positives.

**Input:** `scores` (numeric model scores), `labels` (binary 0/1), `cost_fn` (cost of a false negative), `cost_fp` (cost of a false positive).

**Computation:**
1. Sort unique scores as potential thresholds
2. For each threshold `t`, predict `pred >= t` as fraud
3. Compute `FN = sum(pred == FALSE & labels == 1)`, `FP = sum(pred == TRUE & labels == 0)`
4. Total cost = `FN * cost_fn + FP * cost_fp`
5. Return threshold with minimum total cost

**Assumptions & limits:**
- Threshold is chosen from the *observed* score distribution — no external calibration needed.
- Costs should be assessed by business stakeholder; default `cost_fn = 10, cost_fp = 1` reflects typical fraud-detection asymmetry.
- Does not account for class imbalance beyond the cost ratio.


---


## 10. Fraud rate profile by group

**File:** `R/mart_card_fraud.R::fraud_rate_profile()`<br>
**Packages:** base R

**Purpose:** Compute fraud rate (`k/n`) per group with Wilson confidence intervals, sorted by rate descending.

**Input:** Data frame with `group_col`, `fraud_col` (counts), `total_col` (denominator).

**Computation:**
1. Aggregate `cbind(k, n)` by group (sum)
2. Compute rate = `k / n` (NA when n == 0)
3. Compute Wilson CI per group
4. Sort by rate descending

**Output:** Data frame with `group`, `rate`, `ci_low`, `ci_high`, sorted by `rate` descending.

**Assumptions & limits:**
- Descriptive only — no model discrimination.
- CI coverage depends on Wilson interval properties.


---


## 11. Precision at k

**File:** `R/mart_card_fraud.R::precision_at_k()`<br>
**Packages:** base R

**Purpose:** Precision at top-k when ranking by predicted score.

**Input:** `scores` (numeric), `labels` (binary 0/1), `k` (integer, clamped to `length(scores)`).

**Computation:**
1. Order by `scores` descending
2. Take top-k indices
3. `precision = sum(labels[top-k] == 1) / k`

**Assumptions & limits:**
- Standard metric for rank‑ordered models.
- `k` is clamped if > length.


---


## 12. Average precision (area under PR curve, step-wise)

**File:** `R/mart_card_fraud.R::avg_precision()`<br>
**Packages:** base R

**Purpose:** Compute the area under the precision-recall curve using the step-wise (Riemann) approximation.

**Input:** `scores` (numeric), `labels` (binary 0/1).

**Computation:**
1. Order by scores descending
2. Compute cumulative TP and FP
3. Precision = `tp / (tp + fp)` at each distinct score
4. Recall = `tp / total_positives` at each distinct score
5. `AP = sum(precision * diff(c(0, recall)))`

**Assumptions & limits:**
- Equivalent to PR-AUC with step-wise interpolation.
- If all labels are 0, returns `NA_real_`.


---


## 13. Empirical-Bayes shrinkage (beta-binomial)

**File:** `R/stats_helpers.R::eb_shrink()`<br>
**Packages:** base R

**Purpose:** Shrink a raw rate `k/n` toward a prior mean using a beta-binomial model with uniform prior (alpha=1, beta=1).

**Input:** `k` (successes), `n` (trials), `alpha0`, `beta0` (prior parameters, default 1 each).

**Output:** `(k + alpha0) / (n + alpha0 + beta0)`

**Interpretation:** The shrunk rate is a weighted average of the raw rate and the prior mean (0.5 for uniform prior). When `n` is small, the result is pulled strongly toward 0.5; when `n` is large, the result approaches the raw rate.

**Assumptions & limits:**
- Uniform prior (alpha=beta=1) is the default; replace with informed prior if available.
- Not appropriate for rates that are not binomial proportions.


---


## 14. Individuals control chart (3-sigma limits)

**File:** `R/monitoring.R::individuals_limits()`<br>
**Packages:** base R

**Purpose:** Compute 3-sigma control limits for an individuals chart (X chart), using the moving range (MR) method.

**Input:** Numeric vector `x` (time-ordered).

**Computation:**
1. `m <- mean(x, na.rm = TRUE)`
2. `mr <- abs(diff(x))` — moving ranges
3. `mr_bar <- mean(mr, na.rm = TRUE)`
4. `sigma <- mr_bar / 1.128` (factor to estimate sigma from MR)
5. `list(center = m, lcl = m - 3 * sigma, ucl = m + 3 * sigma, sigma = sigma)`

**Assumptions & limits:**
- Requires `n >= 2` (at least one moving range).
- Assumes data are independent and identically distributed around the process mean.
- Not appropriate for autocorrelated series without pre-processing.


---


## 15. Robust z-score (median/MAD)

**File:** `R/mart_branch_performance.R::robust_z()`<br>
**Packages:** base R

**Purpose:** Compute robust z-scores using median and median absolute deviation (MAD), resistant to outliers.

**Input:** Numeric vector `x`.

**Computation:**
1. `med <- median(x, na.rm = TRUE)`
2. `mad <- mad(x, na.rm = TRUE)` — median absolute deviation
3. Return `(x - med) / (1.4826 * mad)`
4. If `mad == 0`: return `rep(NA_real_, length(x))`

**Assumptions & limits:**
- MAD is scaled to match standard deviation under normality (factor 1.4826).
- More resistant than classic z-score (`mean/sd`) when outliers are present.


---


## 16. Shrink rank (empirical-Bayes ranking of rates)

**File:** `R/mart_branch_performance.R::shrink_rank()`<br>
**Packages:** base R + `stats_helpers.R::eb_shrink()`

**Purpose:** Rank branches by their shrunken rate (active_accounts / total_accounts) so small branches are not over-ranked on noise.

**Input:** Data frame `df`, `id_col`, `k_col` (successes), `n_col` (trials), `alpha0`, `beta0` (priors, default 1 each).

**Output:** Data frame with `id`, `k`, `n`, `raw_rate`, `shrunk_rate`, `rank` (ordered by shrunk_rate descending).

**Shrinking formula:** `shrunk = (k + alpha0) / (n + alpha0 + beta0)` (uniform prior → `eb_shrink(k, n)`).

**Assumptions & limits:**
- Uniform prior may not be appropriate for all domains; use informed priors if available.
- Small branches (small `n`) are pulled strongly toward the prior; large branches are barely affected.


---


## 17. SLA compliance with Wilson interval

**File:** `R/mart_support_performance.R::sla_compliance()`<br>
**Packages:** base R + `R/mart_card_fraud.R::wilson_interval()`

**Purpose:** Compute compliance rate and Wilson confidence interval.

**Input:** `within` (count resolved within SLA), `total` (total count).

**Output:** List with `rate` (within/total) and `ci` (c(lower, upper)).

**Assumptions & limits:**
- Same as Wilson interval (section 8).
- `within > total` produces `rate > 1` — caller should guard against this.


---


## 18. Log-time summary (geometric mean and median)

**File:** `R/mart_support_performance.R::log_time_summary()`<br>
**Packages:** base R

**Purpose:** Summarise right-skewed resolution times using log-scale statistics.

**Input:** Numeric vector `x` (positive resolution times in days).

**Output:** `c(median = exp(median(log(x))), mean = exp(mean(log(x))))`.

**Assumptions & limits:**
- All values must be positive — `x[x > 0]` filters non-positive before logging.
- Geometric mean is the appropriate central tendency for log-normal data.


---


## 19. Kaplan-Meier survival fit

**File:** `R/mart_loan_portfolio.R::survival_fit()`<br>
**Packages:** `survival`

**Purpose:** Fit a Kaplan-Meier survival curve for time-to-default (or time-to-event) with right-censoring.

**Input:** `time` (follow-up time in months), `event` (1 = default/event, 0 = censored).

**Output:** `survfit` object from `survival::survfit(survival::Surv(time, event) ~ 1)`.

**Censoring policy:** Open loans (no default event) are right-censored at their last observation. This is the correct treatment — open loans are not "good", they are simply "still ongoing".

**Assumptions & limits:**
- Requires `survival` package.
- Ties in event times are handled by Efron's approximation in `survfit`.
- Survival curve is descriptive only — does not condition on covariates (use Cox PH for that).


---


## 20. Vintage cohort triangle

**File:** `R/mart_loan_portfolio.R::vintage_triangle()`<br>
**Packages:** base R

**Purpose:** Aggregate loan balances by cohort (month_opened) and months-on-book (mob).

**Input:** Data frame with `cohort_col` (e.g. "2023-01"), `mob_col` (1, 2, 3, ...), and `value_col` (e.g. loan amount).

**Computation:** `aggregate(value, by = list(cohort = cohort, mob = mob), FUN = sum)`

**Output:** Data frame with `cohort`, `mob`, `x` (sum of values).

**Assumptions & limits:**
- Cohort labels should be in "YYYY-MM" format or comparable date strings.
- The sum `sum(x)` across all cohort/mob cells gives total outstanding principal.


---


*Methods documented here are the authoritative reference. If a method is used in `R/` but not documented here, add it to this file. If a method in this file is not implemented in `R/`, implement it or remove the reference.*