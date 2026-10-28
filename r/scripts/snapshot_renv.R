# Snapshot renv.lock from DESCRIPTION. Run once where R is installed, then commit r/renv.lock.
# Usage: Rscript r/scripts/snapshot_renv.R
root <- if (file.exists("DESCRIPTION")) "." else "r"
setwd(root)
if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv", repos = "https://cloud.r-project.org")
desc <- read.dcf("DESCRIPTION")
imports <- strsplit(gsub("\n", "", desc[1, "Imports"]), ",\\s*")[[1]]
suggests <- strsplit(gsub("\n", "", desc[1, "Suggests"]), ",\\s*")[[1]]
suggests <- gsub(" \\(.*\\)", "", suggests)
pkgs <- unique(c(imports, suggests, "duckdb", "testthat", "withr", "ggplot2"))
renv::install(pkgs, prompt = FALSE)
renv::snapshot(type = "all", prompt = FALSE)
cat("renv.lock written in", getwd(), "\n")
