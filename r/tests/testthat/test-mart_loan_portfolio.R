test_that("vintage_triangle aggregates cohort x mob", {
  df <- data.frame(
    cohort = c("2023-01", "2023-01", "2023-02"),
    mob = c(1, 2, 1),
    amt = c(100, 200, 150)
  )
  out <- bankinganalytics::vintage_triangle(df, "cohort", "mob", "amt")
  expect_equal(nrow(out), 3)
  expect_equal(sum(out$x), 450)
})

test_that("hhi of equal shares is 1/n", {
  expect_equal(bankinganalytics::hhi(rep(0.25, 4)), 0.25, tolerance = 1e-12)
})

test_that("survival_fit errors without survival or with bad input", {
  skip_if_not_installed("survival")
  fit <- bankinganalytics::survival_fit(c(1, 2, 3, 4), c(1, 1, 0, 1))
  expect_s3_class(fit, "survfit")
})
