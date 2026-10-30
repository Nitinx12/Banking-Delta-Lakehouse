# Forecasting modules for Banking Delta Lakehouse.
# Implements rolling-origin backtesting for ETS and ARIMA models against a
# seasonal-naive benchmark, plus a future projection.
#
# Marts such as mart_monthly_transactions have many rows per month (one per
# channel / region / ...). Every function here first collapses the data to ONE
# value per month with `agg`. Use `sum` for flows and counts (the default),
# `mean` only for genuinely averaged measures.

.require_forecast_pkgs <- function() {
  # fable::ARIMA() runs unit-root tests through feasts and urca, but both are only
  # "Suggests" of fable. If either is missing, every ARIMA fit fails quietly and
  # accuracy() returns NaN for that model, so fail loudly here instead.
  for (p in c("fable", "fabletools", "feasts", "urca", "tsibble")) {
    if (!requireNamespace(p, quietly = TRUE)) {
      stop(sprintf("Package '%s' required", p), call. = FALSE)
    }
  }
  invisible(TRUE)
}

#' Collapse a data frame to one value per month
#'
#' @param df data frame, any number of rows per month
#' @param date_col,value_col column names (strings)
#' @param agg function used to combine rows of the same month (default `sum`)
#' @return a monthly tsibble with columns `month` and `y`, with no gaps and no NA
#' @keywords internal
.monthly_series <- function(df, date_col, value_col, agg = sum) {
  if (!is.function(agg)) stop("`agg` must be a function such as sum or mean.", call. = FALSE)
  absent <- setdiff(c(date_col, value_col), names(df))
  if (length(absent)) {
    stop(sprintf("Column(s) not found: %s", paste(absent, collapse = ", ")), call. = FALSE)
  }
  if (nrow(df) == 0L) stop("No rows to build a monthly series from.", call. = FALSE)

  ts <- df |>
    dplyr::transmute(month = tsibble::yearmonth(.data[[date_col]]),
                     y     = as.numeric(.data[[value_col]])) |>
    dplyr::filter(!is.na(month)) |>
    dplyr::group_by(month) |>
    dplyr::summarise(y = if (all(is.na(y))) NA_real_ else agg(y, na.rm = TRUE),
                     .groups = "drop") |>
    tsibble::as_tsibble(index = month) |>
    tsibble::fill_gaps()   # inserts missing months as NA so they are caught below

  bad <- ts$month[is.na(ts$y)]
  if (length(bad)) {
    bankinganalytics::log_warn(sprintf("Monthly series has %d missing/NA month(s), e.g. %s. Interpolating.",
                 length(bad), paste(format(utils::head(bad, 6)), collapse = ", ")))
    ts <- ts |> tidyr::fill(y, .direction = "downup")
  }
  ts

}

#' Rolling-origin backtest of ETS / ARIMA against a seasonal-naive benchmark
#'
#' The last `h` months are held out of the training origins so that every fold's
#' forecast window falls inside the observed data (no scoring against missing
#' future values).
#'
#' @param df data frame, one or more rows per month
#' @param date_col,value_col column names (strings)
#' @param h Forecast horizon (months)
#' @param initial Training window size of the first fold (months)
#' @param step Step size for rolling origin (months)
#' @param agg Function combining rows of the same month (default `sum`)
#' @return accuracy table, one row per model
#' @export
backtest_forecast <- function(df, date_col, value_col, h = 3, initial = 24, step = 1,
                              agg = sum) {
  .require_forecast_pkgs()
  ts <- .monthly_series(df, date_col, value_col, agg)

  n <- nrow(ts)
  if (n < initial + h) {
    stop(sprintf("Series too short for backtest: %d months, need at least %d (initial %d + h %d).",
                 n, initial + h, initial, h), call. = FALSE)
  }

  folds <- ts |>
    dplyr::slice_head(n = n - h) |>
    tsibble::stretch_tsibble(.init = initial, .step = step)

  fit <- folds |>
    fabletools::model(
      snaive = fable::SNAIVE(y),
      ets    = fable::ETS(y),
      arima  = fable::ARIMA(y)
    )

  acc <- fabletools::accuracy(fabletools::forecast(fit, h = h), ts)

  if (anyNA(acc$RMSE)) {
    warning("Backtest: no usable forecasts for model(s): ",
            paste(acc$.model[is.na(acc$RMSE)], collapse = ", "), call. = FALSE)
  }
  acc
}

#' Generate a future forecast for a measure
#'
#' @param df data frame, one or more rows per month
#' @param date_col,value_col column names (strings)
#' @param h Forecast horizon (months)
#' @param agg Function combining rows of the same month (default `sum`)
#' @param level Prediction interval level in percent (default 95)
#' @return data frame with `month` (Date, first of month), `.model`, `.mean`,
#'   `.lower`, `.upper`
#' @export
forecast_future <- function(df, date_col, value_col, h = 6, agg = sum, level = 95) {
  .require_forecast_pkgs()
  ts <- .monthly_series(df, date_col, value_col, agg)

  if (nrow(ts) < 12) {
    stop(sprintf("Series too short to forecast: %d months, need at least 12.", nrow(ts)),
         call. = FALSE)
  }

  fit <- ts |>
    fabletools::model(
      ets   = fable::ETS(y),
      arima = fable::ARIMA(y)
    )

  band <- paste0(level, "%")
  out <- fabletools::forecast(fit, h = h) |>
    fabletools::hilo(level = level) |>
    as.data.frame()

  # `hilo` columns expose $lower and $upper directly.
  data.frame(
    month  = as.Date(out$month),
    .model = out$.model,
    .mean  = out$.mean,
    .lower = out[[band]]$lower,
    .upper = out[[band]]$upper,
    stringsAsFactors = FALSE
  )
}
