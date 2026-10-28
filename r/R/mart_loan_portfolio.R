# Pure analysis functions for mart_loan_portfolio.

#' Vintage cohort triangle: cohort by month_opened, performance by months-on-book
#' @param df data frame with cohort_col and mob_col and value_col.
#' @export
vintage_triangle <- function(df, cohort_col, mob_col, value_col) {
  stats::aggregate(df[[value_col]], by = list(cohort = df[[cohort_col]], mob = df[[mob_col]]), FUN = sum)
}

#' HHI concentration
#' @param shares Numeric vector of shares (summing to ~1).
#' @export
hhi <- function(shares) {
  shares <- as.numeric(shares)
  sum(shares^2)
}

#' Kaplan-Meier placeholder wrapper (requires survival)
#' @export
survival_fit <- function(time, event) {
  if (!requireNamespace("survival", quietly = TRUE)) stop("survival not installed", call. = FALSE)
  survival::survfit(survival::Surv(time, event) ~ 1)
}
