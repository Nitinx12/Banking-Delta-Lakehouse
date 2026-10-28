# Pure analysis functions for mart_branch_performance.

#' Funnel control limits for a proportion (binomial)
#' @param n_trials vector of denominators, p_bar overall rate.
#' @export
funnel_limits <- function(n_trials, p_bar, z = 3) {
  se <- sqrt(p_bar * (1 - p_bar) / n_trials)
  list(lower = p_bar - z * se, upper = p_bar + z * se)
}

#' Robust z-score (median/MAD)
#' @export
robust_z <- function(x) {
  med <- median(x, na.rm = TRUE)
  mad <- stats::mad(x, na.rm = TRUE)
  if (mad == 0) return(rep(NA_real_, length(x)))
  (x - med) / (1.4826 * mad)
}
