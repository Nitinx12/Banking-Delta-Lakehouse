# R-side protection against silent schema drift.

#' Validate a mart extract against its contract
#' @param df The mart as a data frame.
#' @param mart Mart name (used in messages).
#' @param spec Contract for this mart.
#' @return `df`, invisibly.
#' @export
assert_contract <- function(df, mart, spec) {
  req <- unlist(spec$required_cols)
  if (length(req) == 0L) {
    log_warn(sprintf("contract for %s has no required_cols yet - nothing is being enforced", mart))
  }

  missing <- setdiff(req, names(df))
  if (length(missing)) {
    stop(sprintf("[%s] missing columns: %s", mart, paste(missing, collapse = ", ")),
         call. = FALSE)
  }

  key <- unlist(spec$key)
  if (length(key) && anyDuplicated(df[key]) > 0L) {
    stop(sprintf("[%s] duplicate rows on key (%s)", mart, paste(key, collapse = ", ")),
         call. = FALSE)
  }

  for (col in unlist(spec$not_null)) {
    if (!col %in% names(df)) {
      stop(sprintf("[%s] not_null column missing: %s", mart, col), call. = FALSE)
    }
    if (anyNA(df[[col]])) {
      stop(sprintf("[%s] NULL values in %s", mart, col), call. = FALSE)
    }
  }

  for (col in names(spec$ranges)) {
    if (!col %in% names(df)) {
      stop(sprintf("[%s] range column missing: %s", mart, col), call. = FALSE)
    }
    lo <- spec$ranges[[col]]$min %||% -Inf
    hi <- spec$ranges[[col]]$max %||% Inf
    bad <- sum(df[[col]] < lo | df[[col]] > hi, na.rm = TRUE)
    if (bad > 0L) {
      stop(sprintf("[%s] %d rows out of range in %s", mart, bad, col), call. = FALSE)
    }
  }
  invisible(df)
}
