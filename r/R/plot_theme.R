# One ggplot theme + palette for every figure.

#' Bank theme for ggplot2
#' @export
theme_bank <- function() {
  if (!requireNamespace("ggplot2", quietly = TRUE)) return(NULL)
  ggplot2::theme_minimal(base_size = 11)
}

#' Bank palette
#' @export
bank_palette <- function(n = 5) {
  grDevices::hcl.colors(n, palette = "Dark 2")
}
