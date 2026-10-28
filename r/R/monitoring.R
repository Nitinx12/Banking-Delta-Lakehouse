# Monitoring: PSI vs previous run, control charts.

#' Individuals control chart limits (3 sigma)
#' @param x numeric vector.
#' @export
individuals_limits <- function(x) {
  m <- mean(x, na.rm = TRUE)
  mr <- abs(diff(x))
  mr_bar <- mean(mr, na.rm = TRUE)
  sigma <- mr_bar / 1.128
  list(center = m, lcl = m - 3 * sigma, ucl = m + 3 * sigma, sigma = sigma)
}

#' Flag points outside control limits
#' @export
control_flags <- function(x, limits = individuals_limits(x)) {
  x < limits$lcl | x > limits$ucl
}

#' PSI of a numeric vector against a reference
#' @export
psi_check <- function(reference, current, bins = 10) {
  bankinganalytics::psi(reference, current, bins = bins)
}
