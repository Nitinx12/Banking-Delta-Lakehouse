test_that("assert_marts_ready flags empty mart", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA marts")
  DBI::dbExecute(con, "CREATE TABLE marts.mart_demo (month_start DATE)")
  cfg <- list(marts = list(mart_demo = list(freshness_col = "month_start", max_age_hours = 24)),
              gate = list(default_max_age_hours = 30))
  expect_error(bankinganalytics::assert_marts_ready(con, cfg), "empty")
})

test_that("assert_marts_ready passes fresh", {
  skip_if_not_installed("duckdb")
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE SCHEMA marts")
  DBI::dbExecute(con, "CREATE TABLE marts.mart_demo (month_start DATE)")
  DBI::dbExecute(con, "INSERT INTO marts.mart_demo VALUES (CURRENT_DATE)")
  cfg <- list(marts = list(mart_demo = list(freshness_col = "month_start", max_age_hours = 10000)),
              gate = list(default_max_age_hours = 30))
  expect_true(bankinganalytics::assert_marts_ready(con, cfg))
})
