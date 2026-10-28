# Shared small helpers.

#' Null-coalescing operator
#' @export
`%||%` <- function(x, y) if (is.null(x)) y else x
