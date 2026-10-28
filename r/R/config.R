# Configuration. This is the ONLY file that reads environment variables.

#' Path relative to the project root
#' @param ... Path components.
#' @export
project_path <- function(...) {
  file.path(getOption("bankinganalytics.root", getwd()), ...)
}

#' Read an environment variable
#' @param name Variable name.
#' @param default Returned when the variable is unset or empty. If NULL, a missing
#'   variable is an error.
#' @export
cfg_env <- function(name, default = NULL) {
  val <- Sys.getenv(name, unset = NA_character_)
  if (is.na(val) || !nzchar(val)) {
    if (!is.null(default)) {
      return(default)
    }
    stop(sprintf("Missing required environment variable: %s", name), call. = FALSE)
  }
  val
}

#' Load config/analysis.yml
#' @param path Path to the YAML file.
#' @export
cfg_analysis <- function(path = project_path("config", "analysis.yml")) {
  if (!file.exists(path)) stop("Config not found: ", path, call. = FALSE)
  yaml::read_yaml(path)
}

#' Load config/contracts.yml
#' @param path Path to the YAML file.
#' @export
cfg_contracts <- function(path = project_path("config", "contracts.yml")) {
  if (!file.exists(path)) stop("Contracts not found: ", path, call. = FALSE)
  yaml::read_yaml(path)
}

#' Root folder for run outputs (R_OUTPUT_DIR, default <root>/output)
#' @export
output_dir <- function() {
  cfg_env("R_OUTPUT_DIR", project_path("output"))
}
