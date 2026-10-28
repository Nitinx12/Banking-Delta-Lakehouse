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
