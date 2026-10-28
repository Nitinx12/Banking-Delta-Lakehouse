# Exit 0/1 gate check usable from Make or Airflow.
suppressPackageStartupMessages({
  if (requireNamespace("pkgload", quietly = TRUE) && dir.exists("R")) pkgload::load_all(".")
})
cfg <- bankinganalytics::cfg_analysis()
con <- bankinganalytics::with_pg(function(c) {
  bankinganalytics::assert_marts_ready(c, cfg)
  TRUE
})
quit(status = 0)
