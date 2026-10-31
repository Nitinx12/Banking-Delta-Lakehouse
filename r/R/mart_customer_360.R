# Pure analysis functions for mart_customer_360.

#' Lorenz curve + Gini + top-decile share
#' @param x Numeric vector of balances/values.
#' @export
concentration <- function(x) {
  x <- sort(as.numeric(x), decreasing = FALSE)
  cumshare <- cumsum(x) / sum(x)
  top_decile <- sum(x > stats::quantile(x, 0.9, na.rm = TRUE)) / sum(x)
  list(gini = bankinganalytics::gini(x), top_decile_share = top_decile, lorenz = cumshare)
}

#' RFM quantile scoring
#' @param df data frame with recency, frequency, monetary columns.
#' @export
rfm_score <- function(df, recency_col, frequency_col, monetary_col, n = 5) {
  score_col <- function(col, inverse = FALSE) {
    rks <- rank(df[[col]], ties.method = "first")
    breaks <- seq(0, length(rks), length.out = n + 1)
    scores <- as.integer(cut(rks, breaks = breaks, include.lowest = TRUE))
    if (inverse) n + 1 - scores else scores
  }

  r <- score_col(recency_col, inverse = TRUE)
  f <- score_col(frequency_col)
  m <- score_col(monetary_col)
  data.frame(r = r, f = f, m = m, rfm = paste0(r, f, m))
}

#' Segment profile table: size, mean monetary, share of total value per RFM segment.
#' @param df Customer data frame with rfm columns (from rfm_score) and a value column.
#' @param segment_col Name of the segment column (e.g. "rfm").
#' @param value_col Name of the monetary value column to aggregate.
#' @export
segment_profile <- function(df, segment_col, value_col) {
  if (!segment_col %in% names(df)) stop("segment_col missing", call. = FALSE)
  if (!value_col %in% names(df)) stop("value_col missing", call. = FALSE)
  g <- as.character(df[[segment_col]])
  v <- as.numeric(df[[value_col]])

  # Use a more robust aggregation to handle NA
  agg <- stats::aggregate(v, by = list(segment = g), FUN = function(z) {
    c(n = length(z), sum = sum(z, na.rm = TRUE), mean = mean(z, na.rm = TRUE))
  })

  tot_v <- sum(v, na.rm = TRUE)
  out <- data.frame(
    segment = agg$segment,
    n_customers = as.integer(agg$x[, "n"]),
    total_value = agg$x[, "sum"],
    mean_value = agg$x[, "mean"],
    share_of_value = agg$x[, "sum"] / tot_v
  )
  out[order(-out$total_value), ]
}

#' Product-holding distribution: count and value share by number of products held.
#' @param df Customer data frame with a products_held column and a value column.
#' @export
product_holding_summary <- function(df, products_col, value_col) {
  p <- as.integer(df[[products_col]])
  v <- as.numeric(df[[value_col]])
  agg <- stats::aggregate(
    v,
    by = list(products = p),
    FUN = function(z) c(n = length(z), total = sum(z))
  )
  out <- data.frame(
    products = agg$products,
    n_customers = as.integer(agg$x[, "n"]),
    total_value = agg$x[, "total"]
  )
  out$share_of_value <- out$total_value / sum(out$total_value)
  out[order(out$products), ]
}
