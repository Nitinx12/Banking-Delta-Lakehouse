library(testthat)
library(bankinganalytics)

test_that("log functions do not error", {
  expect_invisible(log_info("hello {x}", x = 1))
  expect_invisible(log_warn("warn {x}", x = 2))
  expect_invisible(log_error("err {x}", x = 3))
})
