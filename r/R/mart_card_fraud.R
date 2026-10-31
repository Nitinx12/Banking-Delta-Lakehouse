# Pure analysis functions for mart_card_fraud.

#' Fraud rate by group with Wilson interval
#' @param k Fraud count, n total.
#' @export
wilson_interval <- function(k, n, conf = 0.95) {
  if (n == 0) return(c(NA, NA))
  z <- stats::qnorm(1 - (1 - conf) / 2)
  p <- k / n
  denom <- 1 + z^2 / n
  centre <- (p + z^2 / (2 * n)) / denom
  half <- z * sqrt(p * (1 - p) / n + z^2 / (4 * n^2)) / denom
  c(centre - half, centre + half)
}

#' Threshold by cost: choose cutoff minimising expected cost
#' @param scores Numeric scores, labels 0/1, cost_fn, cost_fp.
#' @export
cost_threshold <- function(scores, labels, cost_fn = 10, cost_fp = 1) {
  thr <- sort(unique(scores))
  costs <- vapply(thr, function(t) {
    pred <- scores >= t
    fn <- sum(pred == FALSE & labels == 1)
    fp <- sum(pred == TRUE & labels == 0)
    fn * cost_fn + fp * cost_fp
  }, numeric(1))
  thr[which.min(costs)]
}

#' Fraud-rate profile by a grouping dimension with Wilson intervals.
#' @param df Data frame with group, fraud_count and total_count columns.
#' @param group_col,fraud_col,total_col Column names.
#' @export
fraud_rate_profile <- function(df, group_col, fraud_col, total_col) {
  g <- as.character(df[[group_col]])
  k <- as.numeric(df[[fraud_col]])
  n <- as.numeric(df[[total_col]])
  agg <- stats::aggregate(
    cbind(k, n),
    by = list(group = g),
    FUN = sum
  )
  agg$rate <- ifelse(agg$n == 0, NA_real_, agg$k / agg$n)
  ci <- t(vapply(seq_len(nrow(agg)), function(i) wilson_interval(agg$k[i], agg$n[i]), numeric(2)))
  agg$ci_low <- ci[, 1]
  agg$ci_high <- ci[, 2]
  agg[order(-agg$rate), ]
}

#' Precision at top-k given scores and binary labels.
#' @export
precision_at_k <- function(scores, labels, k) {
  k <- min(k, length(scores))
  ord <- order(scores, decreasing = TRUE)
  pred_pos <- ord[seq_len(k)]
  sum(labels[pred_pos] == 1) / k
}

#' Average precision (area under the PR curve, step-wise).
#' @export
avg_precision <- function(scores, labels) {
  if (sum(labels == 1) == 0) return(NA_real_)
  ord <- order(scores, decreasing = TRUE)
  y <- labels[ord]
  tp <- cumsum(y == 1)
  fp <- cumsum(y == 0)
  prec <- tp / (tp + fp)
  rec <- tp / sum(y == 1)
  sum(prec * diff(c(0, rec)))
}
