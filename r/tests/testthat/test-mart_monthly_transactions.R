test_that("backtest_forecast errors without tsibble/fable", {
  skip_if(requireNamespace("tsibble", quietly = TRUE) && requireNamespace("fable", quietly = TRUE))
  df <- data.frame(m = as.Date("2020-01-01") + 0:30, y = rnorm(31))
  expect_error(bankinganalytics::backtest_forecast(df, "m", "y"), "tsibble|fable")
})

test_that("backtest_forecast errors on short series", {
  skip_if_not_installed("tsibble")
  short <- data.frame(m = as.Date("2020-01-01") + c(0, 31, 62), y = 1:3)
  expect_error(
    bankinganalytics::backtest_forecast(short, "m", "y", h = 3, initial = 2),
    "gaps|too short"
  )
})
