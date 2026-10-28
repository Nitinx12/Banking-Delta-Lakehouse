# Pure analysis functions for mart_card_fraud.

#' Fraud rate by group with Wilson interval
#' @param k Fraud count, n total.
#' @export
wilson_interval <- function(k, n, conf = 0.95) {
  if (n == 0) return(c(NA, NA))
  z <- qnorm(1 - (1 - conf) / 2)
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
