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
