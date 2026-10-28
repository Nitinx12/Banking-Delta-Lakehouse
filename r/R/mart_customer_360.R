# Pure analysis functions for mart_customer_360.

#' Lorenz curve + Gini + top-decile share
#' @param x Numeric vector of balances/values.
#' @export
concentration <- function(x) {
  x <- sort(as.numeric(x), decreasing = FALSE)
  n <- length(x)
  cumshare <- cumsum(x) / sum(x)
  top_decile <- sum(x > quantile(x, 0.9, na.rm = TRUE)) / sum(x)
  list(gini = gini(x), top_decile_share = top_decile, lorenz = cumshare)
}

#' RFM quantile scoring
#' @param df data frame with recency, frequency, monetary columns.
#' @export
rfm_score <- function(df, recency_col, frequency_col, monetary_col, n = 5) {
  r <- n + 1 - as.integer(cut(df[[recency_col]], breaks = quantile(df[[recency_col]], probs = seq(0, 1, length.out = n + 1), na.rm = TRUE), include.lowest = TRUE))
  f <- as.integer(cut(df[[frequency_col]], breaks = quantile(df[[frequency_col]], probs = seq(0, 1, length.out = n + 1), na.rm = TRUE), include.lowest = TRUE))
  m <- as.integer(cut(df[[monetary_col]], breaks = quantile(df[[monetary_col]], probs = seq(0, 1, length.out = n + 1), na.rm = TRUE), include.lowest = TRUE))
  data.frame(r = r, f = f, m = m, rfm = paste0(r, f, m))
}
