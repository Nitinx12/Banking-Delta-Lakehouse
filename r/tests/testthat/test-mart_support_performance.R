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
