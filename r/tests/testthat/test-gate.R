make_gate_db <- function() {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = parent.frame())
  DBI::dbExecute(con, "CREATE SCHEMA marts")
  DBI::dbExecute(con, "CREATE TABLE marts.mart_demo (month_start DATE)")
  DBI::dbExecute(con, "CREATE SCHEMA audit")
  DBI::dbExecute(con, "CREATE TABLE audit.v_dq_latest (layer VARCHAR, status VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO audit.v_dq_latest VALUES ('marts', 'PASS')")
  DBI::dbExecute(con, paste(
    "CREATE TABLE audit.pipeline_runs",
    "(pipeline_run_id VARCHAR, status VARCHAR, started_at TIMESTAMP, ended_at TIMESTAMP)"
  ))
  DBI::dbExecute(con, paste(
    "INSERT INTO audit.pipeline_runs",
    "VALUES ('run-1', 'SUCCESS', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
  ))
  DBI::dbExecute(con, paste(
    "CREATE TABLE audit.table_runs",
    "(pipeline_run_id VARCHAR, processing_layer VARCHAR, status VARCHAR)"
  ))
  con
}

gate_cfg <- function(max_age_hours = 24) {
  list(
    marts = list(mart_demo = list(freshness_col = "month_start",
                                  max_age_hours = max_age_hours)),
    gate = list(default_max_age_hours = 30, check_audit = TRUE)
  )
}

test_that("assert_marts_ready flags empty mart", {
  skip_if_not_installed("duckdb")
  con <- make_gate_db()
  expect_error(bankinganalytics::assert_marts_ready(con, gate_cfg()), "empty")
})

test_that("assert_marts_ready passes fresh", {
  skip_if_not_installed("duckdb")
  con <- make_gate_db()
  DBI::dbExecute(con, "INSERT INTO marts.mart_demo VALUES (CURRENT_DATE)")
  expect_true(bankinganalytics::assert_marts_ready(con, gate_cfg(10000)))
})

test_that("assert_marts_ready blocks a failing marts DQ verdict", {
  skip_if_not_installed("duckdb")
  con <- make_gate_db()
  DBI::dbExecute(con, "INSERT INTO marts.mart_demo VALUES (CURRENT_DATE)")
  DBI::dbExecute(con, "UPDATE audit.v_dq_latest SET status = 'FAIL'")
  expect_error(bankinganalytics::assert_marts_ready(con, gate_cfg(10000)), "DQ check")
})

test_that("assert_marts_ready blocks a failed pipeline run", {
  skip_if_not_installed("duckdb")
  con <- make_gate_db()
  DBI::dbExecute(con, "INSERT INTO marts.mart_demo VALUES (CURRENT_DATE)")
  DBI::dbExecute(con, "UPDATE audit.pipeline_runs SET status = 'FAILED'")
  expect_error(bankinganalytics::assert_marts_ready(con, gate_cfg(10000)),
               "latest pipeline run is FAILED")
})

test_that("assert_marts_ready blocks PARTIAL with a failed marts table run", {
  skip_if_not_installed("duckdb")
  con <- make_gate_db()
  DBI::dbExecute(con, "INSERT INTO marts.mart_demo VALUES (CURRENT_DATE)")
  DBI::dbExecute(con, "UPDATE audit.pipeline_runs SET status = 'PARTIAL'")
  DBI::dbExecute(con, "INSERT INTO audit.table_runs VALUES ('run-1', 'marts', 'FAILED')")
  expect_error(bankinganalytics::assert_marts_ready(con, gate_cfg(10000)),
               "failed marts table run")
})

test_that("assert_marts_ready accepts PARTIAL when marts tables succeeded", {
  skip_if_not_installed("duckdb")
  con <- make_gate_db()
  DBI::dbExecute(con, "INSERT INTO marts.mart_demo VALUES (CURRENT_DATE)")
  DBI::dbExecute(con, "UPDATE audit.pipeline_runs SET status = 'PARTIAL'")
  DBI::dbExecute(con, "INSERT INTO audit.table_runs VALUES ('run-1', 'marts', 'SUCCESS')")
  expect_true(bankinganalytics::assert_marts_ready(con, gate_cfg(10000)))
})

test_that("assert_marts_ready blocks PARTIAL with no marts table runs", {
  skip_if_not_installed("duckdb")
  con <- make_gate_db()
  DBI::dbExecute(con, "INSERT INTO marts.mart_demo VALUES (CURRENT_DATE)")
  DBI::dbExecute(con, "UPDATE audit.pipeline_runs SET status = 'PARTIAL'")
  expect_error(bankinganalytics::assert_marts_ready(con, gate_cfg(10000)),
               "no marts table runs")
})
