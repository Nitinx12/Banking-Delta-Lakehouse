# Pure analysis functions for mart_support_performance.

#' SLA compliance share with Wilson interval
#' @export
sla_compliance <- function(within, total) {
  p <- within / total
  ci <- wilson_interval(within, total)
  list(rate = p, ci = ci)
}

#' Right-skewed resolution time: log-scale summary
#' @export
log_time_summary <- function(x) {
  lx <- log(x[x > 0])
  c(median = exp(median(lx)), mean = exp(mean(lx)))
}

#' Monthly SLA trend: compliance rate and Wilson interval per month.
#' @param df Data frame with date_col, within_col (resolved within SLA) and total_col.
#' @export
sla_trend <- function(df, date_col, within_col, total_col) {
  d <- as.Date(df[[date_col]])
  w <- as.numeric(df[[within_col]])
  t <- as.numeric(df[[total_col]])
  agg <- stats::aggregate(cbind(w, t), by = list(month = d), FUN = sum)
  names(agg)[2:3] <- c("within", "total")
  agg$rate <- ifelse(agg$total == 0, NA_real_, agg$within / agg$total)
  ci <- t(vapply(seq_len(nrow(agg)), function(i) wilson_interval(agg$within[i], agg$total[i]), numeric(2)))
  agg$ci_low <- ci[, 1]
  agg$ci_high <- ci[, 2]
  agg[order(agg$month), ]
}

#' Workload balance: tickets (or resolution load) per agent/group with robust outlier flags.
#' @param df Data frame with agent_col and load_col.
#' @export
workload_balance <- function(df, agent_col, load_col) {
  agent <- as.character(df[[agent_col]])
  load <- as.numeric(df[[load_col]])
  z <- bankinganalytics::robust_z(load)
  out <- data.frame(
    agent = agent,
    load = load,
    z = z,
    outlier = !is.na(z) & abs(z) > 3,
    stringsAsFactors = FALSE
  )
  out[order(-out$load), ]
}
