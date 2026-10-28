# Pure analysis functions for mart_monthly_transactions.

#' Rolling-origin backtest of ETS/ARIMA against seasonal naive
#' @param df data frame with one row per month
#' @param date_col,value_col column names (strings)
#' @export
backtest_forecast <- function(df, date_col, value_col, h = 3, initial = 24, step = 1) {
  if (!requireNamespace("tsibble", quietly = TRUE)) stop("tsibble not installed", call. = FALSE)
  if (!requireNamespace("fable", quietly = TRUE)) stop("fable not installed", call. = FALSE)
  ts <- df |>
    dplyr::transmute(month = tsibble::yearmonth(.data[[date_col]]),
                     y     = .data[[value_col]]) |>
    tsibble::as_tsibble(index = month)

  if (any(tsibble::has_gaps(ts)$.gaps)) {
    stop("Monthly series has gaps; fix upstream or handle explicitly.", call. = FALSE)
  }
  if (nrow(ts) < initial + h) stop("Series too short for requested backtest.", call. = FALSE)

  ts |>
    tsibble::stretch_tsibble(.init = initial, .step = step) |>
    fabletools::model(
      snaive = fable::SNAIVE(y),
      ets    = fable::ETS(y),
      arima  = fable::ARIMA(y)
    ) |>
    fabletools::forecast(h = h) |>
    fabletools::accuracy(ts)
}

#' Aggregate total amount and count by month from a long transactions mart.
#' @param df Data frame with date_col, amount_col and optional count_col.
#' @export
txn_monthly_totals <- function(df, date_col, amount_col, count_col = NULL) {
  d <- as.Date(df[[date_col]])
  a <- as.numeric(df[[amount_col]])
  out <- stats::aggregate(a, by = list(month_start = d), FUN = sum)
  names(out)[2] <- "total_amount"
  if (!is.null(count_col) && count_col %in% names(df)) {
    c <- as.numeric(df[[count_col]])
    cnt <- stats::aggregate(c, by = list(month_start = d), FUN = sum)
    names(cnt)[2] <- "txn_count"
    out <- merge(out, cnt, by = "month_start", all.x = TRUE)
  }
  out <- out[order(out$month_start), ]
  rownames(out) <- NULL
  out
}

#' Share of a categorical dimension over time (compositional mix).
#' @param df Data frame with date_col, group_col, value_col (weight, e.g. amount or count).
#' @export
txn_mix_share <- function(df, date_col, group_col, value_col) {
  d <- as.Date(df[[date_col]])
  g <- as.character(df[[group_col]])
  v <- as.numeric(df[[value_col]])
  tot <- stats::aggregate(v, by = list(month_start = d), FUN = sum)
  names(tot)[2] <- ".total"
  grp <- stats::aggregate(v, by = list(month_start = d, group = g), FUN = sum)
  names(grp)[3] <- ".value"
  out <- merge(grp, tot, by = "month_start")
  out$share <- out$.value / out$.total
  out <- out[, c("month_start", "group", ".value", "share")]
  names(out)[3] <- "value"
  out[order(out$month_start, out$group), ]
}

#' Anomaly flags on a monthly series via robust z of period-over-period changes.
#' Flags, never deletes. Returns the input with change, z and flag columns.
#' @param df Data frame sorted by date.
#' @param date_col,value_col Column names.
#' @export
txn_anomaly_flags <- function(df, date_col, value_col) {
  v <- as.numeric(df[[value_col]])
  chg <- c(NA, diff(v))
  z <- bankinganalytics::robust_z(chg[-1])
  z_full <- c(NA_real_, z)
  data.frame(
    period = df[[date_col]],
    value = v,
    change = chg,
    z = z_full,
    flag = !is.na(z_full) & abs(z_full) > 3
  )
}

#' Log-difference growth rate and CAGR with bootstrap CI.
#' @param start_value,end_value Beginning and ending values.
#' @param n_years Number of years between them.
#' @param times Number of bootstrap resamples for the CI (default 0 = no CI).
#' @export
txn_cagr <- function(start_value, end_value, n_years, conf = 0.95) {
  if (start_value <= 0 || end_value <= 0 || n_years <= 0) {
    stop("start_value, end_value and n_years must be positive", call. = FALSE)
  }
  cagr <- (end_value / start_value)^(1 / n_years) - 1
  list(cagr = cagr)
}
