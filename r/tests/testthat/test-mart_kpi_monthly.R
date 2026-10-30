test_that("kpi_growth computes MoM and YoY diffs", {
  df <- data.frame(
    month_start = seq(as.Date("2020-01-01"), by = "month", length.out = 24),
    value = 1:24
  )
  out <- bankinganalytics::kpi_growth(df, "month_start", "value")
  expect_equal(nrow(out), 24)
  expect_true(is.na(out$mom[1]))
  expect_equal(out$mom[2], 1)
  expect_true(is.na(out$yoy[12]))
  expect_equal(out$yoy[13], 12)
})

test_that("kpi_variance_bridge returns period/value/delta", {
  df <- data.frame(period = 1:3, value = c(10, 12, 15))
  out <- bankinganalytics::kpi_variance_bridge(df, "value")
  expect_true(all(c("period", "value", "delta") %in% names(out)))
  expect_equal(out$delta[2], 2)
})

test_that("kpi_variance_bridge splits a delta into volume, rate and interaction", {
  df <- data.frame(
    month_start = as.Date(c("2024-01-01", "2024-02-01")),
    txn_count = c(100, 120),
    txn_amount = c(1000, 1440)
  )
  out <- bankinganalytics::kpi_variance_bridge(df, "txn_amount", "txn_count", "month_start")
  expect_equal(out$delta[2], 440)
  expect_equal(out$volume_effect[2], 200)
  expect_equal(out$rate_effect[2], 200)
  expect_equal(out$interaction[2], 40)
  expect_equal(
    out$volume_effect[2] + out$rate_effect[2] + out$interaction[2],
    out$delta[2]
  )
})

test_that("kpi_variance_bridge errors on a missing count column", {
  df <- data.frame(month_start = as.Date("2024-01-01"), txn_amount = 1000)
  expect_error(
    bankinganalytics::kpi_variance_bridge(df, "txn_amount", "txn_count"),
    "missing count col"
  )
})

test_that("kpi_seasonal_profile aggregates by calendar month", {
  df <- data.frame(
    month_start = seq(as.Date("2020-01-01"), by = "month", length.out = 24),
    value = rep(c(10, 20, 30), 8)
  )
  out <- bankinganalytics::kpi_seasonal_profile(df, "month_start", "value")
  expect_equal(nrow(out), 12)
  expect_equal(sum(out$share_of_year), 1, tolerance = 1e-9)
})

test_that("kpi_break_flags returns logical of same length", {
  x <- c(rep(10, 20), rep(50, 5))
  fl <- bankinganalytics::kpi_break_flags(x)
  expect_length(fl, length(x))
  expect_type(fl, "logical")
})

test_that("kpi_recompute_ratio never averages ratios", {
  r <- bankinganalytics::kpi_recompute_ratio(c(10, 20), c(2, 5))
  expect_equal(r, c(5, 4))
  expect_true(is.na(bankinganalytics::kpi_recompute_ratio(1, 0)))
})
