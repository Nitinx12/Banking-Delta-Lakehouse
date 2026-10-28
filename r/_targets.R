# r/_targets.R - dependency-graph pipeline. Called from main.R via a targets step,
# so the gate, run key and manifest always apply (R.md section 6).

library(targets)
library(tarchetypes)

tar_option_set(
  packages = c("bankinganalytics", "dplyr"),
  format   = "rds",
  seed     = 20261028,
  error    = "stop"
)

cfg <- bankinganalytics::cfg_analysis()

list(
  # always re-evaluated: cheap checks that gate everything else
  tar_target(ctx, bankinganalytics::run_context(), cue = tar_cue("always"), format = "rds"),
  tar_target(gate, bankinganalytics::with_pg(bankinganalytics::assert_marts_ready),
             cue = tar_cue("always"), format = "rds"),

  # change detector per mart -> re-read only when row count / freshness changed
  tar_target(kpi_token, {
    gate
    bankinganalytics::mart_fingerprint("mart_kpi_monthly", cfg$marts$mart_kpi_monthly$freshness_col)
  }, cue = tar_cue("always"), format = "rds"),
  tar_target(kpi_raw, {
    kpi_token
    bankinganalytics::read_mart("mart_kpi_monthly")
  }),
  tar_target(kpi_checked, {
    bankinganalytics::assert_contract(
      kpi_raw, "mart_kpi_monthly",
      bankinganalytics::cfg_contracts()$mart_kpi_monthly
    )
  }),

  tar_target(txn_token, {
    gate
    bankinganalytics::mart_fingerprint("mart_monthly_transactions", cfg$marts$mart_monthly_transactions$freshness_col)
  }, cue = tar_cue("always"), format = "rds"),
  tar_target(txn_raw, {
    txn_token
    bankinganalytics::read_mart("mart_monthly_transactions")
  }),
  tar_target(txn_checked, {
    bankinganalytics::assert_contract(
      txn_raw, "mart_monthly_transactions",
      bankinganalytics::cfg_contracts()$mart_monthly_transactions
    )
  }),

  # Tier 0 / Tier 1 analysis targets (pure functions)
  tar_target(kpi_growth, bankinganalytics::kpi_growth(kpi_checked, "month_start", "txn_amount"),
             format = "rds"),
  tar_target(kpi_seasonal, bankinganalytics::kpi_seasonal_profile(kpi_checked, "month_start", "txn_amount"),
             format = "rds"),
  tar_target(txn_totals, bankinganalytics::txn_monthly_totals(txn_checked, "month_start", "total_amount", "txn_count"),
             format = "rds"),

  # optional forecast: only when tsibble/fable are installed
  tar_target(kpi_backtest, {
    if (requireNamespace("tsibble", quietly = TRUE) && requireNamespace("fable", quietly = TRUE)) {
      bankinganalytics::backtest_forecast(kpi_checked, "month_start", "txn_amount",
                                          h = cfg$forecast_horizon %||% 3, initial = 12)
    } else {
      NULL
    }
  }, format = "rds")
)
