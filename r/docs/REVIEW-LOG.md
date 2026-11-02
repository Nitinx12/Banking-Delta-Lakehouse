# REVIEW-LOG

2026-10-31: Baseline tests PASS 156, SKIP 0; lint 45 warnings.
2026-10-31: Fixed lint to 0 warnings; tests PASS 164, SKIP 0.
2026-10-31: Live DB safety: r_reader not superuser, read-only session, no write privs, raw/staging/analytics denied.
2026-10-31: Gate + contracts verified on live data.
2026-10-31: Full run live_test* SUCCESS; reproducibility 31 tables identical checksums.
2026-10-31: Forced failure (bad DB name) wrote FAILED manifest.
2026-10-31: Coverage 72.3% (floor 60).
2026-10-31: R CMD check: 1 WARNING (leftover ..Rcheck removed) + 2 NOTEs.
2026-11-02: Correctness pass: fraud model type was "gbm" (actually WoE + stats::glm) -> "logistic"; txn_cagr now returns a bootstrap CI when a series is given; duplicate calculate_psi removed (psi kept, empty input -> NA); run_tests.R path fixed; test_forecast.R renamed to test-forecasting-series.R.
2026-11-02: Predictive hardening: time_split() time-ordered split + binary_metrics() (avg precision, precision/recall at k, base rate) wired into step_predict with validation = oos_time_ordered | in_sample; recall_at_k() added; cox_fit() for time-to-default; predictive section added to analysis.yml.
2026-11-02: Tests PASS 206, SKIP 0; lint 0 warnings; coverage 76.2% (floor 60); R CMD check 0 errors, 0 warnings, 3 NOTEs (hidden files, local Quarto render leftovers, "check via R CMD build").
