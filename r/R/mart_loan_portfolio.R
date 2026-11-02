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

#' Kaplan-Meier survival curve for time-to-default (requires survival).
#' Loans still open are input as censored (event = 0), never dropped.
#' @param time Elapsed time per loan (e.g. months on book).
#' @param event 1 = default observed, 0 = censored.
#' @export
survival_fit <- function(time, event) {
  if (!requireNamespace("survival", quietly = TRUE)) stop("survival not installed", call. = FALSE)
  survival::survfit(survival::Surv(time, event) ~ 1)
}

#' Cox proportional-hazards model of time-to-default (requires survival).
#' Handles censoring explicitly and returns hazard ratios with the concordance.
#' @param df Data frame with one row per loan observation.
#' @param time_col Positive elapsed time column (e.g. months_on_book).
#' @param event_col 1 = default observed, 0 = censored.
#' @param features Covariate column names.
#' @return list(model, features, hazard_ratios, concordance)
#' @export
cox_fit <- function(df, time_col, event_col, features) {
  if (!requireNamespace("survival", quietly = TRUE)) stop("survival not installed", call. = FALSE)
  if (!length(features)) stop("at least one feature is required", call. = FALSE)
  reserved <- c(time_col, event_col)
  if (any(features %in% c(reserved, ".time", ".event", "surv_obj"))) {
    stop("features must not include the time or event column", call. = FALSE)
  }
  absent <- setdiff(c(reserved, features), names(df))
  if (length(absent)) {
    stop(sprintf("Column(s) not found: %s", paste(absent, collapse = ", ")), call. = FALSE)
  }
  dat <- df[, c(reserved, features), drop = FALSE]
  names(dat)[1:2] <- c(".time", ".event")
  dat$.time <- as.numeric(dat$.time)
  dat$.event <- as.integer(dat$.event)
  if (anyNA(dat$.time) || any(dat$.time <= 0)) {
    stop("time_col must be positive with no missing values", call. = FALSE)
  }
  if (!any(dat$.event == 1L, na.rm = TRUE)) {
    stop("no observed events; nothing to fit", call. = FALSE)
  }
  dat$surv_obj <- survival::Surv(dat$.time, dat$.event)
  fit <- survival::coxph(stats::reformulate(features, response = "surv_obj"), data = dat)
  list(
    model = fit,
    features = features,
    hazard_ratios = exp(stats::coef(fit)),
    concordance = unname(fit$concordance[1L])
  )
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
