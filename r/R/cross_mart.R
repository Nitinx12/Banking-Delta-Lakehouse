# Tier 0 cross-mart helpers: profile + write_table.

#' Profile a mart data frame
#' @param df Mart data frame.
#' @param mart Mart name.
#' @export
profile_mart <- function(df, mart) {
  if (nrow(df) == 0) stop("No mart data in memory", call. = FALSE)
  out <- data.frame(
    mart = mart,
    column = names(df),
    n = nrow(df),
    n_null = vapply(df, function(x) sum(is.na(x)), integer(1)),
    n_distinct = vapply(df, function(x) length(unique(x)), integer(1)),
    stringsAsFactors = FALSE
  )
  out
}

#' Write a table (aggregates only) under the run dir
#' @param ctx Run context.
#' @param name File name (without extension).
#' @param df Data frame.
#' @export
write_table <- function(ctx, name, df) {
  path <- file.path(ctx$run_dir, "tables", paste0(name, ".csv"))
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(df, path, row.names = FALSE)
  rel <- file.path("tables", paste0(name, ".csv"))
  ctx$outputs <- c(ctx$outputs, rel)
  invisible(path)
}
