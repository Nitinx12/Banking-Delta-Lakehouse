# Run the package tests from r/ whether invoked there or from the repo root.
root <- getwd()
if (!file.exists(file.path(root, "DESCRIPTION")) && file.exists(file.path(root, "r", "DESCRIPTION"))) {
  root <- file.path(root, "r")
}
testthat::test_local(root)
