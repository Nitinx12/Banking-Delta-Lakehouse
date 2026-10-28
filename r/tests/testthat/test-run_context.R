test_that("sanitise_run_key", {
  expect_equal(bankinganalytics::sanitise_run_key("a b!!c"), "a_b_c")
  expect_equal(bankinganalytics::sanitise_run_key("___"), "run")
})

test_that("run_context writes manifest", {
  ctx <- bankinganalytics::run_context("Test Run")
  expect_true(file.exists(ctx$manifest_path))
  m <- jsonlite::read_json(ctx$manifest_path)
  expect_equal(m$status, "RUNNING")
  expect_equal(m$run_key, "Test_Run")
})
