test_that("assert_contract catches missing columns", {
  df <- data.frame(a = 1:3)
  spec <- list(required_cols = c("a", "b"), key = "a", not_null = character(), ranges = list())
  expect_error(bankinganalytics::assert_contract(df, "mart_x", spec), "missing columns")
})

test_that("assert_contract catches duplicates", {
  df <- data.frame(a = c(1, 1))
  spec <- list(required_cols = "a", key = "a", not_null = character(), ranges = list())
  expect_error(bankinganalytics::assert_contract(df, "mart_x", spec), "duplicate rows")
})

test_that("assert_contract catches nulls", {
  df <- data.frame(a = c(1L, NA_integer_))
  spec <- list(required_cols = "a", key = character(), not_null = "a", ranges = list())
  expect_error(bankinganalytics::assert_contract(df, "mart_x", spec), "NULL values")
})

test_that("assert_contract catches range", {
  df <- data.frame(a = c(1, 100))
  spec <- list(required_cols = "a", key = character(), not_null = character(),
               ranges = list(a = list(min = 0, max = 10)))
  expect_error(bankinganalytics::assert_contract(df, "mart_x", spec), "out of range")
})

test_that("assert_contract passes clean", {
  df <- data.frame(a = 1:3, b = c(1, 2, 3))
  spec <- list(required_cols = c("a", "b"), key = "a", not_null = "a", ranges = list())
  expect_invisible(bankinganalytics::assert_contract(df, "mart_x", spec))
})
