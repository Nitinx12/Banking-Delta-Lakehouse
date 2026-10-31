# Pure analysis functions for mart_loan_portfolio.

#' Vintage cohort triangle: cohort by month_opened, performance by months-on-book
#' @param df data frame with cohort_col and mob_col and value_col.
#' @export
vintage_triangle <- function(df, cohort_col, mob_col, value_col) {
  stats::aggregate(
    df[[value_col]],
    by = list(cohort = df[[cohort_col]], mob = df[[mob_col]]),
    FUN = sum
  )
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

#' Portfolio quality summary: recompute ratios from counts/balances, never average ratios.
#' Expects columns: loan_count, total_loan_amount, and optionally late_payment_count
#' (or similar) for delinquency. late_col is the count of late/defaulted loans.
#' @param df Loan portfolio data frame (already filtered to the relevant slice).
#' @param count_col Loan count column name.
#' @param amount_col Outstanding/total amount column name.
#' @param late_col Count of late or defaulted loans (optional).
#' @export
portfolio_quality <- function(df, count_col = "loan_count",
                              amount_col = "total_loan_amount",
                              late_col = NULL) {
  n <- sum(as.numeric(df[[count_col]]), na.rm = TRUE)
  amt <- sum(as.numeric(df[[amount_col]]), na.rm = TRUE)
  out <- list(loan_count = n, total_amount = amt)
  if (!is.null(late_col) && late_col %in% names(df)) {
    late_n <- sum(as.numeric(df[[late_col]]), na.rm = TRUE)
    out$late_count <- late_n
    out$late_rate <- if (n == 0) NA_real_ else late_n / n
  }
  out
}

#' Concentration by a grouping column: HHI and top-N share of amount.
#' @param df Data frame.
#' @param group_col Grouping column (e.g. loan_type, branch).
#' @param amount_col Amount column to concentrate.
#' @param top_n Top-N share denominator (default 5).
#' @export
concentration_by <- function(df, group_col, amount_col, top_n = 5) {
  g <- as.character(df[[group_col]])
  a <- as.numeric(df[[amount_col]])
  s <- stats::aggregate(a, by = list(group = g), FUN = sum)
  names(s)[2] <- "total_amount"
  s <- s[order(-s$total_amount), ]
  tot <- sum(s$total_amount)
  s$share <- s$total_amount / tot
  list(
    hhi = hhi(s$share),
    top_n_share = sum(utils::head(s$share, top_n)),
    table = s
  )
}
