test_that("theme_bank returns a theme or NULL without ggplot2", {
  th <- bankinganalytics::theme_bank()
  expect_true(is.null(th) || inherits(th, "theme"))
})

test_that("bank_palette returns n colours", {
  cols <- bankinganalytics::bank_palette(4)
  expect_length(cols, 4)
})
