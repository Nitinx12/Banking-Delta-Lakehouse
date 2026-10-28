test_that("%||% works", {
  expect_equal(NULL %||% 5, 5)
  expect_equal(3 %||% 5, 3)
})
