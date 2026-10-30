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

test_that("txn_monthly_totals sums amount by month", {
  df <- data.frame(
    m = as.Date(c("2020-01-01", "2020-01-15", "2020-02-01")),
    amt = c(100, 50, 200),
    cnt = c(1, 1, 2)
  )
  out <- bankinganalytics::txn_monthly_totals(df, "m", "amt", "cnt")
  expect_equal(nrow(out), 2)
  expect_equal(out$total_amount, c(150, 200))
  expect_equal(out$txn_count, c(2, 2))
})

test_that("txn_mix_share shares sum to 1 per month", {
  df <- data.frame(
    m = as.Date(c("2020-01-01", "2020-01-01", "2020-02-01", "2020-02-01")),
    g = c("a", "b", "a", "b"),
    v = c(30, 70, 50, 50)
  )
  out <- bankinganalytics::txn_mix_share(df, "m", "g", "v")
  s <- tapply(out$share, out$month_start, sum)
  expect_true(all(abs(s - 1) < 1e-9))
})

test_that("txn_anomaly_flags flags a far change", {
  v <- c(
    97, 98, 94, 102, 104, 100, 102, 106, 109, 107,
    115, 117, 114, 103, 109, 109, 109, 114, 118, 618
  )
  df <- data.frame(m = as.Date("2020-01-01") + 0:19, v = v)
  out <- bankinganalytics::txn_anomaly_flags(df, "m", "v")
  expect_true(out$flag[20])
  expect_false(any(out$flag[1:18], na.rm = TRUE))
})

test_that("txn_cagr computes compound growth", {
  res <- bankinganalytics::txn_cagr(100, 121, 2)
  expect_equal(res$cagr, 0.1, tolerance = 1e-9)
  expect_error(bankinganalytics::txn_cagr(-1, 10, 2), "positive")
})
