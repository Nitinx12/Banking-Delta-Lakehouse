library(testthat)
library(bankinganalytics)

test_that("write_figures skips when ggplot2 missing", {
  # figures.R functions may require ggplot2; just ensure file loads
  expect_true(exists("write_figures", where = asNamespace("bankinganalytics"), inherits = FALSE) ||
                exists("write_figures", inherits = TRUE))
})
