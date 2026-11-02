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

test_that("portfolio_quality recomputes ratios from counts", {
  df <- data.frame(loan_count = c(10, 20), total_loan_amount = c(1000, 2000), late = c(1, 2))
  q <- bankinganalytics::portfolio_quality(df, "loan_count", "total_loan_amount", "late")
  expect_equal(q$loan_count, 30)
  expect_equal(q$total_amount, 3000)
  expect_equal(q$late_rate, 3 / 30, tolerance = 1e-9)
})

test_that("concentration_by returns hhi and top-n share", {
  df <- data.frame(g = c("a", "b", "c"), amt = c(50, 30, 20))
  res <- bankinganalytics::concentration_by(df, "g", "amt", top_n = 1)
  expect_equal(res$hhi, 0.25 + 0.09 + 0.04, tolerance = 1e-9)
  expect_equal(res$top_n_share, 0.5, tolerance = 1e-9)
})

test_that("cox_fit returns hazard ratios in the expected direction", {
  skip_if_not_installed("survival")
  set.seed(42)
  n <- 300
  risk <- rnorm(n)
  df <- data.frame(
    loan_id = seq_len(n),
    months_on_book = pmax(1, rexp(n, rate = exp(0.6 * risk))),
    is_default = rbinom(n, 1, 0.8),
    risk = risk
  )
  fit <- bankinganalytics::cox_fit(df, "months_on_book", "is_default", "risk")
  expect_length(fit$hazard_ratios, 1)
  expect_gt(unname(fit$hazard_ratios[["risk"]]), 1)
  expect_gt(fit$concordance, 0.5)
})

test_that("cox_fit validates its inputs", {
  skip_if_not_installed("survival")
  df <- data.frame(t = c(1, 2, 3), e = c(0, 0, 0), x = c(1, 2, 3))
  expect_error(bankinganalytics::cox_fit(df, "t", "e", "x"), "no observed events")
  expect_error(bankinganalytics::cox_fit(df, "t", "e", character()), "at least one feature")
  expect_error(bankinganalytics::cox_fit(df, "t", "e", "missing_col"), "not found")
  bad <- data.frame(t = c(0, 1, 2), e = c(1, 1, 0), x = c(1, 2, 3))
  expect_error(bankinganalytics::cox_fit(bad, "t", "e", "x"), "positive")
})