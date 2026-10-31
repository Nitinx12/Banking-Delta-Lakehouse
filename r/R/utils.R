# Shared small helpers.

utils::globalVariables(c(".data", "month", "y"))

#' Null-coalescing operator
#' @export
`%||%` <- function(x, y) if (is.null(x)) y else x
# NSE globals used in dplyr/tidyr/tsibble pipelines.
utils::globalVariables(c(".data", "month", "y", ".model", ".mean", ".lower", ".upper"))
