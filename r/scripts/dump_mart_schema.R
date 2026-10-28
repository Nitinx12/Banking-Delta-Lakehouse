# Write docs/DATA-DICTIONARY.md from information_schema for the seven marts.
suppressPackageStartupMessages({
  if (requireNamespace("pkgload", quietly = TRUE) && dir.exists("R")) pkgload::load_all(".")
})
cfg <- bankinganalytics::cfg_analysis()
out <- "# Data dictionary (generated)\n\n"
for (mart in names(cfg$marts)) {
  df <- bankinganalytics::with_pg(function(con) {
    DBI::dbGetQuery(con, sprintf(
      "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema='marts' AND table_name='%s' ORDER BY ordinal_position",
      mart
    ))
  })
  out <- paste0(out, "## ", mart, "\n\n")
  out <- paste0(out, "| column | type | nullable |\n|---|---|---|\n")
  for (i in seq_len(nrow(df))) {
    out <- paste0(out, "| ", df$column_name[i], " | ", df$data_type[i], " | ", df$is_nullable[i], " |\n")
  }
  out <- paste0(out, "\n")
}
dir.create("docs", showWarnings = FALSE)
writeLines(out, "docs/DATA-DICTIONARY.md")
cat("wrote docs/DATA-DICTIONARY.md\n")
