test_that("sla_compliance returns rate and CI", {
  res <- bankinganalytics::sla_compliance(80, 100)
  expect_equal(res$rate, 0.8)
  expect_length(res$ci, 2)
  expect_true(res$ci[1] < 0.8 && res$ci[2] > 0.8)
})

test_that("log_time_summary handles right-skewed positive times", {
  s <- bankinganalytics::log_time_summary(c(1, 2, 3, 10, 100))
  expect_true(s[["median"]] < s[["mean"]])
})

test_that("log_time_summary ignores non-positive values", {
  s <- bankinganalytics::log_time_summary(c(0, -1, 2, 4))
  expect_true(is.finite(s[["median"]]))
})

test_that("sla_trend aggregates by month with intervals", {
  df <- data.frame(
    m = as.Date(c("2020-01-01", "2020-01-15", "2020-02-01")),
    within = c(9, 8, 18),
    total = c(10, 10, 20)
  )
  out <- bankinganalytics::sla_trend(df, "m", "within", "total")
  expect_equal(nrow(out), 2)
  expect_equal(out$rate[1], 17 / 20)
})

test_that("workload_balance flags outliers", {
  df <- data.frame(agent = paste0("a", 1:10), load = c(10, 11, 9, 12, 10, 11, 9, 10, 11, 100))
  out <- bankinganalytics::workload_balance(df, "agent", "load")
  expect_true(out$outlier[1])
  expect_false(any(out$outlier[2:10]))
})
