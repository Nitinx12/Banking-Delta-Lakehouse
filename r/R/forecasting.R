# Forecasting modules for Banking Delta Lakehouse.
# Implements rolling-origin backtesting for ETS and ARIMA models.

#' Rolling-origin backtest of ETS / ARIMA against a seasonal-naive benchmark
#' @param df data frame with one row per month
#' @param date_col,value_col column names (strings)
#' @param h Forecast horizon (months)
#' @param initial Training window size (months)
#' @param step Step size for rolling origin (months)
#' @export
backtest_forecast <- function(df, date_col, value_col, h = 3, initial = 24, step = 1) {
  if (!requireNamespace("fable", quietly = TRUE)) stop("Package 'fable' required")
  if (!requireNamespace("tsibble", quietly = TRUE)) stop("Package 'tsibble' required")
  if (!requireNamespace("fabletools", quietly = TRUE)) stop("Package 'fabletools' required")

  ts <- df |>
    dplyr::transmute(month = tsibble::yearmonth(.data[[date_col]]),
                     y     = .data[[value_col]]) |>
    tsibble::as_tsibble(index = month)

  if (any(tsibble::has_gaps(ts)$.gaps)) {
    stop("Monthly series has gaps; fix upstream or handle explicitly.", call. = FALSE)
  }
  if (nrow(ts) < initial + h) stop("Series too short for requested backtest.", call. = FALSE)

  # Rolling origin backtest
  results <- ts |>
    tsibble::stretch_tsibble(.init = initial, .step = step) |>
    fabletools::model(
      snaive = fable::SNAIVE(y),
      ets    = fable::ETS(y),
      arima  = fable::ARIMA(y)
    ) |>
    fabletools::forecast(h = h) |>
    fabletools::accuracy(ts)

  results
}

#' Generate a future forecast for a measure
#' @param df data frame with monthly data
#' @param date_col,value_col column names
#' @param h Forecast horizon
#' @export
forecast_future <- function(df, date_col, value_col, h = 6) {
  ts <- df |>
    dplyr::transmute(month = tsibble::yearmonth(.data[[date_col]]),
                     y     = .data[[value_col]]) |>
    tsibble::as_tsibble(index = month)

  fit <- ts |>
    fabletools::model(
      ets   = fable::ETS(y),
      arima = fable::ARIMA(y)
    )

  res <- fabletools::forecast(fit, h = h) |>
    fabletools::hilo()
  
  # Coerce the hilo intervals to a matrix and extract columns
  bounds <- as.matrix(res$`95%`)
  
  res |>
    dplyr::mutate(
      .lower = bounds[, 1],
      .upper = bounds[, 2]
    ) |>
    dplyr::select(month, .model, .mean, .lower, .upper)
}
