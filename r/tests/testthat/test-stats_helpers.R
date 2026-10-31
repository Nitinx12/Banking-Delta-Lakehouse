test_that("gini of uniform is 0", {
  expect_equal(bankinganalytics::gini(rep(1, 10)), 0, tolerance = 1e-9)
})

test_that("psi identical ~0", {
  x <- rnorm(100)
  expect_lt(bankinganalytics::psi(x, x), 0.01)
})

test_that("bootstrap_ci returns 2 values", {
  ci <- bankinganalytics::bootstrap_ci(1:10, median, R = 50)
  expect_length(ci, 2)
})

test_that("eb_shrink", {
  expect_equal(bankinganalytics::eb_shrink(5, 10), 6 / 12, tolerance = 1e-9)
})

test_that("wilson_interval", {
  ci <- bankinganalytics::wilson_interval(5, 100)
  expect_length(ci, 2)
  expect_true(ci[1] < 0.05 && ci[2] > 0.05)
})

test_that("concentration gini", {
  res <- bankinganalytics::concentration(c(1, 2, 3, 4, 100))
  expect_true(res$gini > 0.5)
})

test_that("robust_z", {
  z <- bankinganalytics::robust_z(c(1, 2, 3, 4, 100))
  expect_true(is.na(z[5]) == FALSE)
})

test_that("cost_threshold", {
  sc <- c(0.1, 0.2, 0.8, 0.9)
  lab <- c(0, 0, 1, 1)
  t <- bankinganalytics::cost_threshold(sc, lab)
  expect_true(t >= 0.2)
})
