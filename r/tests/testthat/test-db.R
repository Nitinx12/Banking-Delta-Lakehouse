library(testthat)
library(bankinganalytics)

test_that("pg_connect errors without env", {
  withr::local_envvar(c(R_PG_HOST = NA, R_PG_USER = NA, R_PG_PASSWORD = NA))
  expect_error(pg_connect(), "Missing required environment variable")
})
