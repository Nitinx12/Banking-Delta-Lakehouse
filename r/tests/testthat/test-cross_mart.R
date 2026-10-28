test_that("profile_mart works", {
  df <- data.frame(a = 1:5, b = c(1, NA, 3, 4, 5))
  prof <- bankinganalytics::profile_mart(df, "mart_x")
  expect_equal(nrow(prof), 2)
  expect_equal(prof$n_null[prof$column == "b"], 1)
})

test_that("profile_mart errors on empty", {
  df <- data.frame(a = integer())
  expect_error(bankinganalytics::profile_mart(df, "mart_x"), "No mart data")
})
