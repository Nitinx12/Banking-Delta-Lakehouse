# r/_targets.R - dependency graph pipeline (adopt when ready).

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
  tar_target(ctx, bankinganalytics::run_context(), cue = tar_cue("always"), format = "rds"),
  tar_target(gate, bankinganalytics::with_pg(bankinganalytics::assert_marts_ready), cue = tar_cue("always"), format = "rds")
)
