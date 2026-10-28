test_that("check_completeness detects gaps", {
  df <- data.frame(d = as.Date(c("2026-01-01", "2026-03-01")))
  res <- bankinganalytics::check_completeness(df, "d")
  expect_false(res$ok)
  expect_length(res$missing, 1)
})

test_that("check_completeness ok", {
  df <- data.frame(d = as.Date(c("2026-01-01", "2026-02-01")))
  res <- bankinganalytics::check_completeness(df, "d")
  expect_true(res$ok)
})

test_that("individuals_limits", {
  lim <- bankinganalytics::individuals_limits(1:20)
  expect_true(lim$ucl > lim$center)
})

test_that("control_flags returns logical vector", {
  x <- c(1,2,3,4,5)
  fl <- bankinganalytics::control_flags(x)
  expect_type(fl, "logical")
  expect_length(fl, length(x))
})
