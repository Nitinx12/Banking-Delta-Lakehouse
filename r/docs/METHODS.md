# Methods

Every method used in `r/`: purpose, assumptions, validation, known limits.
Functions live in `R/`; this file is the narrative layer. When you add a method,
add an entry here in the same commit.

## Descriptive and trust (Tier 0–1)

### Gini coefficient — `gini()`, `concentration()`

- **Purpose.** Measure inequality / concentration of a monetary distribution
  (balances, exposure, spend).
- **Assumptions.** Non-negative values; scale-invariant.
- **Validation.** Unit test: uniform vector → Gini 0; heavily skewed vector → Gini > 0.5.
- **Limits.** Sensitive to the top tail; always pair with a Lorenz curve and top-decile share.
  Never report Gini alone.

### Population Stability Index — `psi()`, `psi_check()`

- **Purpose.** Detect distribution shift between a reference and a current sample
  (features, scores, segment mix).
- **Assumptions.** Reference defines the bin edges; both samples non-empty; bins ≥ 2 after
  unique-quantile collapse.
- **Validation.** Unit test: PSI(x, x) < 0.01.
- **Rules of thumb.** PSI < 0.1 stable; 0.1–0.25 investigate; > 0.25 material shift.
  PSI is not a hypothesis test — report it with sample sizes.

### Bootstrap confidence interval — `bootstrap_ci()`

- **Purpose.** Non-parametric interval for any scalar statistic (median, Gini, CAGR).
- **Assumptions.** i.i.d. resampling is acceptable for the statistic; fixed seed for
  reproducibility (default `20261028`).
- **Validation.** Unit test: returns exactly two quantiles.
- **Limits.** Wide intervals on small n; prefer BCa or stratified bootstrap when the
  statistic is biased or the sample is grouped.

### Empirical-Bayes shrinkage — `eb_shrink()`

- **Purpose.** Fair ranking of rates (e.g. branch NPS, SLA hit-rate) so small groups are
  not over-ranked on noise.
- **Assumptions.** Beta-binomial conjugate prior with uniform default (`alpha0 = beta0 = 1`).
- **Validation.** Unit test: `eb_shrink(5, 10) = 6/12`.
- **Limits.** The default prior is weakly informative; for heavily skewed branches set
  `alpha0`/`beta0` from the pooled rate. Always show raw n alongside the shrunk rate.

### Wilson score interval — `wilson_interval()`

- **Purpose.** Interval for a proportion that behaves correctly near 0 and 1
  (unlike Wald).
- **Assumptions.** Binomial sampling; `n > 0`.
- **Validation.** Unit test: interval brackets the observed rate; `n = 0` → `NA`.
- **Limits.** For very large n the interval is numerically fine but over-precise for
  business reporting — round thoughtfully.

### Robust z-score — `robust_z()`

- **Purpose.** Outlier flagging on ratios that are not normal (branch metrics, ticket times).
- **Assumptions.** Median/MAD is a stable location/scale pair; MAD > 0.
- **Validation.** Unit test: far outlier z > 3; constant vector → all `NA`.
- **Limits.** MAD = 0 on constant data returns `NA` by design — do not silently replace
  with 0.

### Individuals control chart — `individuals_limits()`, `control_flags()`

- **Purpose.** Separate common-cause noise from special-cause shifts in a monthly KPI.
- **Assumptions.** Series is approximately stationary; MR-bar / 1.128 estimates sigma.
- **Validation.** Unit test: single far point is flagged, in-control points are not.
- **Limits.** Needs ≥ ~15 points for a meaningful sigma; for seasonal series detrend first
  or use an S-chart variant.

## Diagnostic (Tier 2)

### RFM quantile scoring — `rfm_score()`

- **Purpose.** Segment customers on recency, frequency and monetary value without fitting
  a clustering model.
- **Assumptions.** Quantile cuts are stable within a run; recency is "days since last
  transaction" (higher = worse, hence inverted score).
- **Validation.** Unit test: returns r/f/m/rfm columns with one row per input row.
- **Limits.** Quantile bins are sample-relative — scores are not comparable across runs
  without freezing the cut points. Prefer GMM/k-means when segments must be stable over time.

### Vintage triangle — `vintage_triangle()`

- **Purpose.** Track cohort performance (e.g. delinquency) by months-on-book.
- **Assumptions.** Cohort and MOB columns are present and correctly coded upstream.
- **Validation.** Unit test: aggregation sums to the input total.
- **Limits.** Open cohorts have incomplete triangles — never average across MOB without
  accounting for censoring.

### HHI concentration — `hhi()`

- **Purpose.** Portfolio concentration by product, branch or segment.
- **Assumptions.** Shares sum to ~1.
- **Validation.** Unit test: equal shares of n → HHI = 1/n.
- **Limits.** HHI is insensitive to the tail shape; pair with top-N share.

### Funnel control limits — `funnel_limits()`

- **Purpose.** Control band for a rate plotted against volume, so small branches are not
  spuriously flagged.
- **Assumptions.** Binomial variance; p_bar is the pooled rate.
- **Validation.** Unit test: limits widen as n shrinks.
- **Limits.** Over-dispersion (common in branch data) widens the true band — consider a
  beta-binomial variance if many points fall outside.

## Predictive (Tier 3)

### Rolling-origin forecast backtest — `backtest_forecast()`

- **Purpose.** Honest out-of-sample accuracy for ETS/ARIMA against a seasonal-naive
  benchmark.
- **Assumptions.** Monthly series with no gaps; `tsibble`, `fable`, `fabletools` installed.
- **Validation.** Unit test: errors cleanly on missing packages and on short/gappy series.
- **Rules.** A forecast is only reported if it beats SNAIVE on the backtest. Always report
  prediction intervals, not just point forecasts.
- **Limits.** Rolling-origin is computationally expensive for long series; step > 1 trades
  accuracy for speed.

### Cost-based classification threshold — `cost_threshold()`

- **Purpose.** Choose a fraud/default cut-off that minimises expected cost
  (FN cost × FN count + FP cost × FP count).
- **Assumptions.** Scores and labels are aligned; costs are on the same scale.
- **Validation.** Unit test: threshold falls between the highest negative and lowest
  positive score on a clean example.
- **Limits.** Assumes a single operating point; if the alert budget is fixed, choose by
  precision@k instead.

### Kaplan–Meier survival — `survival_fit()`

- **Purpose.** Time-to-default / time-to-resolution with right censoring.
- **Assumptions.** Non-informative censoring; `survival` package installed.
- **Validation.** Unit test (skipped if `survival` missing): returns a `survfit` object.
- **Limits.** Univariate only; open loans/tickets must be coded as censored (`event = 0`),
  never dropped.

## Privacy and export

### ID hashing — `hash_id()`

- **Purpose.** Pseudonymise customer/branch IDs before any export or figure.
- **Assumptions.** Input is character; SHA-256 truncated to 12 hex chars.
- **Validation.** Unit test: deterministic, different inputs → different hashes.
- **Limits.** Truncation to 12 chars (~48 bits) is fine for linkage within a run but is
  not a cryptographic commitment — do not use for audit trails.

### Small-cell suppression — `suppress_small_cells()`

- **Purpose.** Replace measure values in cells with n below the configured threshold
  (default 10 from `analysis.yml`) before any table or figure leaves the run.
- **Assumptions.** An `n_col` with cell counts is present; threshold comes from config.
- **Validation.** Unit test: rows below threshold get `NA` measures; missing `n_col` is a
  no-op.
- **Limits.** Suppression is not differencing control — a determined adversary can still
  subtract complementary cells. For public release apply complementary suppression too.

## Cross-mart trust

### Cross-mart reconciliation — `reconcile_txns_vs_kpi()`

- **Purpose.** Verify `mart_monthly_transactions.total_amount` rolls up to
  `mart_kpi_monthly.txn_amount` per month, in SQL, to the cent.
- **Assumptions.** Both marts are built from the same fact source; `month_start` aligns.
- **Validation.** Unit test exists for `check_completeness`; reconciliation itself needs a
  live connection (integration tier).
- **Limits.** A non-zero diff is a hard stop for publication — do not apply a tolerance to
  money.

### Period completeness — `check_completeness()`

- **Purpose.** Detect missing months in a date-grain mart (gaps break forecasts and YoY).
- **Assumptions.** Monthly grain; date column is coercible to `Date`.
- **Validation.** Unit test: contiguous months → `ok = TRUE`; a gap is reported in
  `missing`.
- **Limits.** Calendar-month sequence assumes no intentional non-monthly grain.
