# Write docs/DATA-DICTIONARY.md (relative to the current directory) from
# information_schema for every mart listed in config/analysis.yml.
# Works from the repo root or from r/.

root <- getwd()
if (!file.exists(file.path(root, "DESCRIPTION")) && file.exists(file.path(root, "r", "DESCRIPTION"))) {
  root <- file.path(root, "r")
}
if (!file.exists(file.path(root, "DESCRIPTION"))) {
  cat("dump_mart_schema: DESCRIPTION not found; run from the repo root or r/\n", file = stderr())
  quit(status = 2)
}
options(bankinganalytics.root = normalizePath(root))

if (requireNamespace("pkgload", quietly = TRUE) && dir.exists(file.path(root, "R"))) {
  suppressPackageStartupMessages(pkgload::load_all(root, quiet = TRUE))
} else {
  suppressPackageStartupMessages(library(bankinganalytics))
}

cfg <- bankinganalytics::cfg_analysis()

# One connection for all marts, and a parameterised query instead of sprintf().
sql <- paste(
  "SELECT column_name, data_type, is_nullable",
  "FROM information_schema.columns",
  "WHERE table_schema = 'marts' AND table_name = $1",
  "ORDER BY ordinal_position"
)

out <- bankinganalytics::with_pg(function(con) {
  lines <- c("# Data dictionary (generated)", "")
  for (mart in names(cfg$marts)) {
    df <- DBI::dbGetQuery(con, sql, params = list(mart))
    lines <- c(lines, paste0("## ", mart), "")
    if (nrow(df) == 0L) {
      warning(sprintf("no columns found for marts.%s", mart), call. = FALSE)
      lines <- c(lines, "_No columns found (table missing or no privileges)._", "")
      next
    }
    lines <- c(lines, "| column | type | nullable |", "|---|---|---|",
               sprintf("| %s | %s | %s |", df$column_name, df$data_type, df$is_nullable), "")
  }
  lines
})

dir.create("docs", showWarnings = FALSE)
writeLines(out, "docs/DATA-DICTIONARY.md")
cat("wrote docs/DATA-DICTIONARY.md\n")
