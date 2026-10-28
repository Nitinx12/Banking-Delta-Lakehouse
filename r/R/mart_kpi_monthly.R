# Pure analysis functions for mart_kpi_monthly.

#' Variance bridge: additive decomposition into volume/mix/rate (placeholder)
#' @param df data frame with numerator, denominator columns.
#' @export
kpi_variance_bridge <- function(df, value_col) {
  if (!value_col %in% names(df)) stop("missing value col", call. = FALSE)
  data.frame(
    period = df[[1]],
    value = df[[value_col]],
    delta = c(NA, diff(df[[value_col]]))
  )
}

#' Rolling MoM/QoQ/YoY growth
#' @export
kpi_growth <- function(df, date_col, value_col) {
  v <- df[[value_col]]
  data.frame(
    period = df[[date_col]],
    value = v,
    mom = c(NA, diff(v)),
    yoy = c(rep(NA, 12), diff(v, lag = 12))
  )
}

#' Month-of-year seasonal profile for a monthly KPI (base R, no feasts needed).
#' Returns mean value and share of annual total per calendar month.
#' @param df Data frame with a date column and a value column.
#' @param date_col Name of the date column (Date or POSIXt).
#' @param value_col Name of the numeric value column.
#' @export
kpi_seasonal_profile <- function(df, date_col, value_col) {
  d <- as.Date(df[[date_col]])
  v <- as.numeric(df[[value_col]])
  mo <- as.integer(format(d, "%m"))
  agg <- stats::aggregate(v, by = list(month = mo), FUN = function(z) c(mean = mean(z), sum = sum(z), n = length(z)))
  out <- data.frame(
    month = agg$month,
    mean_value = agg$x[, "mean"],
    total_value = agg$x[, "sum"],
    n = as.integer(agg$x[, "n"])
  )
  out$share_of_year <- out$total_value / sum(out$total_value)
  out
}

#' Simple structural-break flag via cumulative-mean shift (CUSUM-style).
#' Flags points where the running mean deviates more than k*sd from the global mean.
#' @param x Numeric vector (time-ordered).
#' @param k Sensitivity multiplier (default 1.5).
#' @export
kpi_break_flags <- function(x, k = 1.5) {
  n <- length(x)
  if (n < 6) return(rep(FALSE, n))
  g <- mean(x, na.rm = TRUE)
  s <- stats::sd(x, na.rm = TRUE)
  if (is.na(s) || s == 0) return(rep(FALSE, n))
  cum <- cumsum(x - g) / seq_len(n)
  abs(cum) > k * s / sqrt(seq_len(n))
}

#' Ratio re-computed from numerator and denominator (never average a ratio column).
#' @param num Numerator vector.
#' @param den Denominator vector.
#' @export
kpi_recompute_ratio <- function(num, den) {
  if (length(num) != length(den)) stop("num and den must have equal length", call. = FALSE)
  ifelse(den == 0, NA_real_, num / den)
}
