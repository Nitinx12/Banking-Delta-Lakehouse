test_that("individuals_limits computes 3-sigma from MR", {
  lim <- bankinganalytics::individuals_limits(1:20)
  expect_true(is.list(lim))
  expect_true(lim$lcl < lim$center && lim$center < lim$ucl)
})

test_that("control_flags marks outliers", {
  x <- c(rep(10, 19), 100)
  fl <- bankinganalytics::control_flags(x)
  expect_true(fl[20])
  expect_false(any(fl[1:19]))
})

test_that("psi_check delegates to psi", {
  x <- rnorm(50)
  expect_lt(bankinganalytics::psi_check(x, x), 0.01)
})
