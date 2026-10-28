test_that("kpi_growth computes MoM and YoY diffs", {
  df <- data.frame(
    month_start = seq(as.Date("2020-01-01"), by = "month", length.out = 24),
    value = 1:24
  )
  out <- bankinganalytics::kpi_growth(df, "month_start", "value")
  expect_equal(nrow(out), 24)
  expect_true(is.na(out$mom[1]))
  expect_equal(out$mom[2], 1)
  expect_true(is.na(out$yoy[13]))
  expect_equal(out$yoy[14], 1)
})

test_that("kpi_variance_bridge returns period/value/delta", {
  df <- data.frame(period = 1:3, value = c(10, 12, 15))
  out <- bankinganalytics::kpi_variance_bridge(df, "value")
  expect_true(all(c("period", "value", "delta") %in% names(out)))
  expect_equal(out$delta[2], 2)
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
