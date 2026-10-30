# Exit 0/1 gate check usable from Make or Airflow.
# Works from the repo root or from r/ (finds DESCRIPTION either way).

root <- getwd()
if (!file.exists(file.path(root, "DESCRIPTION")) && file.exists(file.path(root, "r", "DESCRIPTION"))) {
  root <- file.path(root, "r")
}
if (!file.exists(file.path(root, "DESCRIPTION"))) {
  cat("check_gate: DESCRIPTION not found; run from the repo root or r/\n", file = stderr())
  quit(status = 2)
}
options(bankinganalytics.root = normalizePath(root))

if (requireNamespace("pkgload", quietly = TRUE) && dir.exists(file.path(root, "R"))) {
  suppressPackageStartupMessages(pkgload::load_all(root, quiet = TRUE))
} else {
  suppressPackageStartupMessages(library(bankinganalytics))
}

ok <- tryCatch({
  cfg <- bankinganalytics::cfg_analysis()
  bankinganalytics::with_pg(function(con) {
    bankinganalytics::assert_marts_ready(con, cfg)
    TRUE
  })
}, error = function(e) {
  cat("GATE FAILED: ", conditionMessage(e), "\n", sep = "", file = stderr())
  FALSE
})

if (ok) cat("gate ok\n")
quit(status = if (isTRUE(ok)) 0L else 1L)
