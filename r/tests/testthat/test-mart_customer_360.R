test_that("concentration reports gini and top-decile share", {
  res <- bankinganalytics::concentration(c(1, 2, 3, 4, 100))
  expect_true(res$gini > 0.5)
  expect_true(res$top_decile_share > 0)
  expect_length(res$lorenz, 5)
})

test_that("rfm_score returns R/F/M columns", {
  df <- data.frame(
    recency = c(10, 20, 30, 40, 50),
    frequency = c(1, 2, 3, 4, 5),
    monetary = c(100, 200, 300, 400, 500)
  )
  out <- bankinganalytics::rfm_score(df, "recency", "frequency", "monetary", n = 5)
  expect_true(all(c("r", "f", "m", "rfm") %in% names(out)))
  expect_equal(nrow(out), 5)
})
