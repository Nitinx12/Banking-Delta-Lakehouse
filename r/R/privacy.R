# Small-cell suppression and id hashing.

#' Hash an id column (SHA-256, truncated) for export
#' @param x Character vector of ids.
#' @export
hash_id <- function(x) {
  vapply(x, function(v) substr(digest::digest(v, algo = "sha256"), 1, 12), character(1))
}

#' Suppress small cells: replace values where n < threshold with NA
#' @param df Data frame.
#' @param n_col Column name with cell counts.
#' @param threshold Minimum cell size.
#' @export
suppress_small_cells <- function(df, n_col, threshold = 10) {
  if (!n_col %in% names(df)) return(df)
  df[df[[n_col]] < threshold, setdiff(names(df), n_col)] <- NA
  df
}
