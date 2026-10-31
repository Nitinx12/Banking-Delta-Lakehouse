# Synthetic mart shaped like mart_monthly_transactions: many rows per month.
make_mart <- function(months = seq(as.Date("2024-01-01"), by = "month", length.out = 34)) {
  set.seed(42)
  n <- length(months)
  base <- (1000 + 12 * seq_len(n)) * (1 + 0.15 * sin(2 * pi * seq_len(n) / 12))
  d <- expand.grid(month_start = months, channel = c("atm", "upi", "pos"),
                   stringsAsFactors = FALSE)
  d$total_amount <- base[match(d$month_start, months)] / 3 + rnorm(nrow(d), 0, 3)
  d
}

skip_if_no_forecast_pkgs <- function() {
  for (p in c("fable", "fabletools", "feasts", "urca", "tsibble")) {
    testthat::skip_if_not_installed(p)
  }
}

test_that(".monthly_series sums rows within a month and does not average", {
  d <- make_mart()
  s <- .monthly_series(d, "month_start", "total_amount", sum)
  expect_equal(nrow(s), 34L)
  expected <- tapply(d$total_amount, d$month_start, sum)
  expect_equal(s$y, as.numeric(expected), ignore_attr = TRUE)
  m <- .monthly_series(d, "month_start", "total_amount", mean)
  expect_equal(m$y * 3, s$y)
})

test_that(".monthly_series rejects gaps and missing columns", {
  d <- make_mart()
  gap <- d[d$month_start != as.Date("2024-06-01"), ]
  expect_error(.monthly_series(gap, "month_start", "total_amount"), "has gaps")
  filled <- .monthly_series(gap, "month_start", "total_amount", interpolate = TRUE)
  expect_equal(nrow(filled), 34L)
  expect_equal(length(attr(filled, "interpolated_months")), 1L)
  expect_error(.monthly_series(d, "month_start", "nope"), "not found")
})

test_that("backtest works on multi-row months with no warnings", {
  skip_if_no_forecast_pkgs()
  d <- make_mart()
  expect_no_warning(bt <- backtest_forecast(d, "month_start", "total_amount"))
  expect_setequal(bt$.model, c("snaive", "ets", "arima"))
  expect_false(anyNA(bt$RMSE))
})

test_that("backtest refuses a series that is too short", {
  skip_if_no_forecast_pkgs()
  d <- make_mart(seq(as.Date("2024-01-01"), by = "month", length.out = 20))
  expect_error(backtest_forecast(d, "month_start", "total_amount"),
               "Series too short for backtest")
})

test_that("forecast_future returns Date months and ordered intervals", {
  skip_if_no_forecast_pkgs()
  f <- forecast_future(make_mart(), "month_start", "total_amount", h = 6)
  expect_s3_class(f$month, "Date")
  expect_equal(nrow(f), 12L)  # 6 months x 2 models
  expect_true(all(f$.lower < f$.mean & f$.mean < f$.upper))
  expect_equal(min(f$month), as.Date("2026-11-01"))
})
