library(testthat)
library(bankinganalytics)

test_that(".assert_mart_name rejects bad names", {
  expect_error(.assert_mart_name("foo"), "Invalid mart name")
  expect_error(.assert_mart_name(123), "Invalid mart name")
  expect_invisible(.assert_mart_name("mart_kpi_monthly"))
})

test_that("mart_stats errors on invalid mart name", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA marts")
  DBI::dbExecute(con, "CREATE TABLE marts.mart_demo (month_start DATE)")
  expect_error(mart_stats(con, "badname"), "Invalid mart name")
})
