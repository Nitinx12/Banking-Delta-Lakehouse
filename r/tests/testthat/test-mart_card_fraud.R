test_that("wilson_interval brackets the observed rate", {
  ci <- bankinganalytics::wilson_interval(5, 100)
  expect_length(ci, 2)
  expect_true(ci[1] < 0.05 && ci[2] > 0.05)
})

test_that("wilson_interval handles zero trials", {
  expect_true(all(is.na(bankinganalytics::wilson_interval(0, 0))))
})

test_that("cost_threshold picks a cutoff that classifies well", {
  scores <- c(0.1, 0.2, 0.8, 0.9)
  labels <- c(0, 0, 1, 1)
  t <- bankinganalytics::cost_threshold(scores, labels, cost_fn = 10, cost_fp = 1)
  expect_true(t >= 0.2 && t <= 0.8)
})

test_that("fraud_rate_profile ranks by rate with intervals", {
  df <- data.frame(
    g = c("mcA", "mcB", "mcA"),
    k = c(2, 5, 1),
    n = c(100, 100, 50)
  )
  out <- bankinganalytics::fraud_rate_profile(df, "g", "k", "n")
  expect_equal(out$group[1], "mcB")
  expect_true(all(out$ci_low <= out$rate & out$rate <= out$ci_high, na.rm = TRUE))
})

test_that("precision_at_k and avg_precision behave on a clean example", {
  scores <- c(0.9, 0.8, 0.3, 0.2)
  labels <- c(1, 1, 0, 0)
  expect_equal(bankinganalytics::precision_at_k(scores, labels, 2), 1)
  expect_equal(bankinganalytics::avg_precision(scores, labels), 1)
})
