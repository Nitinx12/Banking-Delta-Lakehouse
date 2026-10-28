# Shared setup for every analyses/*/index.qmd. Thin: no analysis logic here.
# Tables were written by main.R step_analyses / step_profile / step_monitoring
# under BANKING_RUN_DIR/tables (env var set by step_report).

run_dir <- Sys.getenv("BANKING_RUN_DIR", unset = "")
if (!nzchar(run_dir)) {
  candidates <- list.dirs(file.path("output", "runs"), full.names = TRUE, recursive = FALSE)
  if (length(candidates)) run_dir <- candidates[which.max(file.info(candidates)$mtime)]
}

read_table <- function(name) {
  path <- file.path(run_dir, "tables", paste0(name, ".csv"))
  if (!file.exists(path)) return(NULL)
  utils::read.csv(path, stringsAsFactors = FALSE)
}

has_run <- nzchar(run_dir) && dir.exists(file.path(run_dir, "tables"))
