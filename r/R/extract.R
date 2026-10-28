# Reading marts. Marts are small by design, so a full read is fine.

.assert_mart_name <- function(mart) {
  if (!is.character(mart) || length(mart) != 1L || !grepl("^mart_[a-z0-9_]+$", mart)) {
    stop("Invalid mart name: ", format(mart), call. = FALSE)
  }
  invisible(mart)
}

#' Row count and latest freshness value of one mart
#' @param con A DBI connection.
#' @param mart Mart table name.
#' @param freshness_col Optional column whose maximum is the freshness marker.
#' @export
mart_stats <- function(con, mart, freshness_col = NULL) {
  .assert_mart_name(mart)
  tbl <- dplyr::tbl(con, DBI::Id(schema = "marts", table = mart))
  n <- dplyr::pull(dplyr::count(tbl), "n")
  latest <- NULL
  if (!is.null(freshness_col)) {
    col <- rlang::sym(freshness_col)
    latest <- dplyr::pull(
      dplyr::summarise(tbl, latest = max(!!col, na.rm = TRUE)),
      "latest"
    )
  }
  list(n = as.numeric(n), latest = latest)
}

#' Fingerprint a mart on its own connection
#' @export
mart_fingerprint <- function(mart, freshness_col = NULL) {
  with_pg(function(con) mart_stats(con, mart, freshness_col))
}

#' Read a whole mart
#' @param mart Mart table name.
#' @param token Unused value that lets a pipeline declare a dependency on a fingerprint.
#' @export
read_mart <- function(mart, token = NULL) {
  .assert_mart_name(mart)
  force(token)
  with_pg(function(con) {
    dplyr::collect(dplyr::tbl(con, DBI::Id(schema = "marts", table = mart)))
  })
}
