# Snapshot renv.lock from DESCRIPTION. Run once where R is installed, then commit r/renv.lock.
# Usage: Rscript r/scripts/snapshot_renv.R
root <- if (file.exists("DESCRIPTION")) "." else "r"
setwd(root)
if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv", repos = "https://cloud.r-project.org")

# Package names listed in a DESCRIPTION field, without version constraints.
# Tolerates a missing field, multi-line values and "pkg (>= 1.2)" entries.
desc_pkgs <- function(desc, field) {
  if (!field %in% colnames(desc) || is.na(desc[1, field])) return(character())
  x <- strsplit(desc[1, field], ",")[[1]]
  x <- gsub("\\([^)]*\\)", "", x)
  x <- gsub("\\s+", "", x)
  x[nzchar(x) & x != "R"]
}

desc <- read.dcf("DESCRIPTION")
pkgs <- unique(c(
  desc_pkgs(desc, "Depends"),
  desc_pkgs(desc, "Imports"),
  desc_pkgs(desc, "Suggests"),
  "duckdb", "testthat", "withr", "ggplot2",
  # fable::ARIMA() needs these at run time but they are only "Suggests" upstream
  "feasts", "urca"
))
renv::install(pkgs, prompt = FALSE)
renv::snapshot(type = "all", prompt = FALSE)
cat("renv.lock written in", getwd(), "\n")
