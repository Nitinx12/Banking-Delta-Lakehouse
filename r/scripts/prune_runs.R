# Prune run folders older than retention_days (from config/analysis.yml).
# Usage: Rscript r/scripts/prune_runs.R [--dry-run] [output_dir]
root <- if (file.exists("DESCRIPTION")) "." else "r"
options(bankinganalytics.root = normalizePath(root))
if (requireNamespace("pkgload", quietly = TRUE) && dir.exists(file.path(root, "R"))) {
  suppressPackageStartupMessages(pkgload::load_all(root, quiet = TRUE))
} else {
  suppressPackageStartupMessages(library(bankinganalytics))
}

# `%||%` is only in base R >= 4.4.
`%||%` <- function(a, b) if (is.null(a)) b else a

cfg <- bankinganalytics::cfg_analysis()
retention <- cfg$retention_days %||% 30
# A zero, negative or non-numeric value would delete every run folder.
if (!is.numeric(retention) || length(retention) != 1L || is.na(retention) || retention < 1) {
  stop("retention_days must be a single number >= 1, got: ", format(retention), call. = FALSE)
}

args <- commandArgs(trailingOnly = TRUE)
dry_run <- "--dry-run" %in% args
pos <- args[!startsWith(args, "--")]
out_dir <- if (length(pos) >= 1) pos[1] else bankinganalytics::output_dir()
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
    if (dry_run) cat("would remove:", r, "\n") else unlink(r, recursive = TRUE)
    pruned <- pruned + 1L
  }
}
cat(sprintf("%s %d run(s) older than %s days from %s\n",
            if (dry_run) "Would prune" else "Pruned", pruned, format(retention), runs_dir))
