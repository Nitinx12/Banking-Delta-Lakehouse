# Statistical helpers: gini, psi, bootstrap CI, shrinkage, backtests.

#' Gini coefficient
#' @param x Numeric vector.
#' @export
gini <- function(x) {
  x <- sort(as.numeric(x))
  n <- length(x)
  if (n == 0) return(NA_real_)
  num <- sum((2 * seq_len(n) - n - 1) * x)
  den <- n * sum(x)
  if (den == 0) return(NA_real_)
  num / den
}

#' Population Stability Index between two numeric vectors
#' @param expected,actual Numeric vectors.
#' @param bins Number of bins.
#' @export
psi <- function(expected, actual, bins = 10) {
  qs <- unique(quantile(expected, probs = seq(0, 1, length.out = bins + 1), na.rm = TRUE))
  if (length(qs) < 2) return(NA_real_)
  e <- cut(expected, breaks = qs, include.lowest = TRUE)
  a <- cut(actual, breaks = qs, include.lowest = TRUE)
  pe <- prop.table(table(e))
  pa <- prop.table(table(a))
  # align
  all_levels <- union(names(pe), names(pa))
  pe <- pe[all_levels]; pe[is.na(pe)] <- 1e-6
  pa <- pa[all_levels]; pa[is.na(pa)] <- 1e-6
  sum((pa - pe) * log(pa / pe))
}

#' Bootstrap confidence interval for a statistic
#' @param x Numeric vector.
#' @param stat Function returning a scalar.
#' @param R Number of replicates.
#' @param conf Confidence level.
#' @export
bootstrap_ci <- function(x, stat, R = 1000, conf = 0.95, seed = 20261028) {
  set.seed(seed)
  reps <- replicate(R, stat(sample(x, replace = TRUE)))
  alpha <- (1 - conf) / 2
  quantile(reps, c(alpha, 1 - alpha), na.rm = TRUE)
}

#' Empirical-Bayes shrinkage (beta-binomial) for a rate
#' @param k Successes, n trials, prior alpha/beta.
#' @export
eb_shrink <- function(k, n, alpha0 = 1, beta0 = 1) {
  (k + alpha0) / (n + alpha0 + beta0)
}
