# Prune run folders older than retention_days (from config/analysis.yml).
# Usage: Rscript r/scripts/prune_runs.R [output_dir]
root <- if (file.exists("DESCRIPTION")) "." else "r"
options(bankinganalytics.root = normalizePath(root))
if (requireNamespace("pkgload", quietly = TRUE) && dir.exists(file.path(root, "R"))) {
  pkgload::load_all(root)
} else {
  suppressPackageStartupMessages(library(bankinganalytics))
}

cfg <- bankinganalytics::cfg_analysis()
retention <- cfg$retention_days %||% 30
out <- commandArgs(trailingOnly = TRUE)
out_dir <- if (length(out) >= 1) out[1] else bankinganalytics::output_dir()
runs_dir <- file.path(out_dir, "runs")
if (!dir.exists(runs_dir)) {
  cat("No runs directory:", runs_dir, "\n")
  quit(status = 0)
}

cutoff <- Sys.time() - retention * 86400
runs <- list.dirs(runs_dir, full.names = TRUE, recursive = FALSE)
pruned <- 0L
for (r in runs) {
  info <- file.info(r)
  if (!is.na(info$mtime) && info$mtime < cutoff) {
    unlink(r, recursive = TRUE)
    pruned <- pruned + 1L
  }
}
cat(sprintf("Pruned %d run(s) older than %d days from %s\n", pruned, retention, runs_dir))
