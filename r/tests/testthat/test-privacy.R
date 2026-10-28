test_that("hash_id returns truncated sha256", {
  h <- bankinganalytics::hash_id("abc")
  expect_length(h, 1)
  expect_match(h, "^[0-9a-f]{12}$")
  expect_false(identical(h, bankinganalytics::hash_id("abd")))
})

test_that("suppress_small_cells masks rows below threshold", {
  df <- data.frame(n = c(3, 15, 20), v = c(1, 2, 3))
  out <- bankinganalytics::suppress_small_cells(df, "n", threshold = 10)
  expect_true(is.na(out$v[1]))
  expect_equal(out$v[2:3], c(2, 3))
})

test_that("suppress_small_cells no-ops when n_col missing", {
  df <- data.frame(v = 1:3)
  expect_identical(bankinganalytics::suppress_small_cells(df, "n"), df)
})
