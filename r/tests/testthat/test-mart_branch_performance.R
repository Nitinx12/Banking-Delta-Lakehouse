test_that("funnel_limits widen with smaller n", {
  small <- bankinganalytics::funnel_limits(10, 0.1)
  large <- bankinganalytics::funnel_limits(1000, 0.1)
  expect_true((small$upper - small$lower) > (large$upper - large$lower))
})

test_that("robust_z flags a far outlier", {
  z <- bankinganalytics::robust_z(c(1, 2, 3, 4, 100))
  expect_true(abs(z[5]) > 3)
  expect_true(all(abs(z[1:4]) < 3))
})

test_that("robust_z returns NA when MAD is zero", {
  z <- bankinganalytics::robust_z(rep(5, 5))
  expect_true(all(is.na(z)))
})
