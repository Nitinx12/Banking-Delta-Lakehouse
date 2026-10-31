# Shared small helpers.

utils::globalVariables(c(".data", "month", "y"))

#' Null-coalescing operator
#' @export
`%||%` <- function(x, y) if (is.null(x)) y else x
