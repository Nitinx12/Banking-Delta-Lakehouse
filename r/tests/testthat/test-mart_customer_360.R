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

test_that("segment_profile aggregates by segment", {
  df <- data.frame(seg = c("A", "A", "B"), val = c(10, 20, 100))
  out <- bankinganalytics::segment_profile(df, "seg", "val")
  expect_equal(nrow(out), 2)
  expect_equal(sum(out$share_of_value), 1, tolerance = 1e-9)
  expect_equal(out$segment[1], "B")
})

test_that("product_holding_summary groups by product count", {
  df <- data.frame(products = c(1, 1, 2, 3), val = c(10, 20, 30, 40))
  out <- bankinganalytics::product_holding_summary(df, "products", "val")
  expect_equal(nrow(out), 3)
  expect_equal(sum(out$share_of_value), 1, tolerance = 1e-9)
})
