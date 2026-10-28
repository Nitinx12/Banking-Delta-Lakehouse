# The gate: refuse to analyse marts that are empty, unreadable or stale.

#' Stop unless every configured mart is readable, non-empty and fresh enough
#' @param con A DBI connection.
#' @param cfg Parsed analysis.yml.
#' @param now Reference instant (injectable for tests).
#' @export
assert_marts_ready <- function(con, cfg = cfg_analysis(), now = Sys.time()) {
  problems <- character()
  default_age <- cfg$gate$default_max_age_hours %||% 30

  for (mart in names(cfg$marts)) {
    spec  <- cfg$marts[[mart]]
    col   <- spec$freshness_col
    stats <- tryCatch(mart_stats(con, mart, col), error = function(e) e)

    if (inherits(stats, "error")) {
      problems <- c(problems, sprintf("%s unreadable: %s", mart, conditionMessage(stats)))
      next
    }
    if (is.na(stats$n) || stats$n == 0) {
      problems <- c(problems, sprintf("%s is empty", mart))
      next
    }
    if (is.null(col)) {
      log_warn("no freshness_col configured for {mart}; only checking it is non-empty")
      next
    }

    max_age <- spec$max_age_hours %||% default_age
    age_h <- as.numeric(difftime(now, as.POSIXct(stats$latest, tz = "UTC"), units = "hours"))
    if (is.na(age_h) || age_h > max_age) {
      problems <- c(problems, sprintf("%s is stale (%s h old, limit %s h)",
                                      mart, format(round(age_h, 1)), max_age))
    }
  }

  if (length(problems)) {
    stop("Marts not ready:\n - ", paste(problems, collapse = "\n - "), call. = FALSE)
  }
  invisible(TRUE)
}
