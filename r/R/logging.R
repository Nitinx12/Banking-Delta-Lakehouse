# Logger wrapper. No row values, ever.

#' Log an info message
#' @param msg Template with {placeholders}.
#' @param ... Named values for placeholders.
#' @export
log_info <- function(msg, ...) {
  logger::log_info(msg, ...)
}

#' Log a warning
#' @param msg Template with {placeholders}.
#' @param ... Named values for placeholders.
#' @export
log_warn <- function(msg, ...) {
  logger::log_warn(msg, ...)
}

#' Log an error
#' @param msg Template with {placeholders}.
#' @param ... Named values for placeholders.
#' @export
log_error <- function(msg, ...) {
  logger::log_error(msg, ...)
}
