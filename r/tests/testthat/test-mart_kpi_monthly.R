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
