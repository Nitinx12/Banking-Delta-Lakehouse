# Tests for forecasting modules.
library(testthat)
library(bankinganalytics)

test_that("backtest_forecast fails on gaps", {
  df <- data.frame(
    month_start = as.Date(c("2020-01-01", "2020-02-01", "2020-04-01")), # gap in March
    txn_amount = c(100, 110, 120)
  )
  expect_error(backtest_forecast(df, "month_start", "txn_amount"), "has gaps")
})

test_that("backtest_forecast fails on short series", {
  df <- data.frame(
    month_start = seq(as.Date("2020-01-01"), by = "month", length.out = 5),
    txn_amount = rnorm(5)
  )
  expect_error(backtest_forecast(df, "month_start", "txn_amount"), "Series too short")
})

test_that("forecast_future returns correct columns", {
  df <- data.frame(
    month_start = seq(as.Date("2020-01-01"), by = "month", length.out = 36),
    txn_amount = rnorm(36)
  )
  res <- forecast_future(df, "month_start", "txn_amount", h = 6)
  expect_true(all(c("month", ".model", ".mean", ".lower", ".upper") %in% names(res)))
  expect_equal(nrow(res), 6 * 2) # 2 models: ets and arima
})
