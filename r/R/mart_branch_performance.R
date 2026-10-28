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

#' Empirical-Bayes shrunk ranking of a rate so small branches are not over-ranked.
#' @param df Data frame with success_col (k) and trials_col (n) and an id_col.
#' @param id_col Branch identifier column.
#' @param k_col Success/count column.
#' @param n_col Trials/denominator column.
#' @param alpha0,beta0 Prior parameters (default uniform).
#' @export
shrink_rank <- function(df, id_col, k_col, n_col, alpha0 = 1, beta0 = 1) {
  id <- as.character(df[[id_col]])
  k <- as.numeric(df[[k_col]])
  n <- as.numeric(df[[n_col]])
  raw <- ifelse(n == 0, NA_real_, k / n)
  shrunk <- bankinganalytics::eb_shrink(k, n, alpha0, beta0)
  out <- data.frame(
    id = id,
    k = k,
    n = n,
    raw_rate = raw,
    shrunk_rate = shrunk,
    stringsAsFactors = FALSE
  )
  out <- out[order(-out$shrunk_rate, -out$n), ]
  out$rank <- seq_len(nrow(out))
  rownames(out) <- NULL
  out
}

#' Percentile rank of each branch within peer groups (by a size or region column).
#' @param df Data frame with value_col, peer_col and id_col.
#' @export
peer_percentile <- function(df, id_col, value_col, peer_col) {
  id <- as.character(df[[id_col]])
  v <- as.numeric(df[[value_col]])
  peer <- as.character(df[[peer_col]])
  pct <- ave(v, peer, FUN = function(z) {
    if (length(z) < 2) return(rep(100, length(z)))
    rank(z, ties.method = "average") / length(z) * 100
  })
  data.frame(id = id, peer = peer, value = v, percentile = pct, stringsAsFactors = FALSE)
}
