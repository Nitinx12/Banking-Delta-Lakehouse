library(testthat)
library(bankinganalytics)

test_that("cfg_env returns default when missing", {
  withr::local_envvar(c(FOO_BAR_BAZ = NA))
  expect_equal(cfg_env("FOO_BAR_BAZ", "d"), "d")
})

test_that("cfg_env errors when required missing", {
  withr::local_envvar(c(FOO_BAR_BAZ = NA))
  expect_error(cfg_env("FOO_BAR_BAZ"), "Missing required environment variable")
})

test_that("cfg_analysis loads the yaml", {
  tmp <- tempfile(fileext = ".yml")
  writeLines("marts: {}", tmp)
  cfg <- cfg_analysis(tmp)
  expect_true(is.list(cfg))
})

test_that("cfg_contracts errors on missing file", {
  expect_error(cfg_contracts("nope.yml"), "Contracts not found")
})

test_that("output_dir defaults under root", {
  withr::local_envvar(c(R_OUTPUT_DIR = NA))
  options(bankinganalytics.root = normalizePath(getwd(), mustWork = FALSE))
  expect_true(grepl("output", output_dir()))
})
