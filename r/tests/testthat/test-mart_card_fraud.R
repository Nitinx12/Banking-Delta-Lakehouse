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
