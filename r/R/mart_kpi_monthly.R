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
