# Run context: run_key, git SHA, manifest read/write.

#' Sanitise a run key the same way reports/ does
#' @param key Raw run key.
#' @export
sanitise_run_key <- function(key) {
  key <- gsub("[^A-Za-z0-9_]+", "_", key)
  key <- gsub("^_+|_+$", "", key)
  if (!nzchar(key)) key <- "run"
  key
}

#' Best-effort git SHA
#' @export
git_sha <- function() {
  sha <- tryCatch(
    system2("git", c("rev-parse", "--short", "HEAD"), stdout = TRUE, stderr = FALSE),
    error = function(e) NA_character_
  )
  if (length(sha) == 0 || is.na(sha[1]) || !nzchar(sha[1])) {
    Sys.getenv("GIT_SHA", unset = NA_character_)
  } else {
    sha[1]
  }
}

#' Build a run context
#' @param run_key Optional run key (sanitised).
#' @export
run_context <- function(run_key = NULL) {
  root <- getOption("bankinganalytics.root", getwd())
  if (is.null(run_key) || !nzchar(run_key)) {
    run_key <- Sys.getenv("R_RUN_KEY", unset = "")
  }
  if (!nzchar(run_key)) {
    run_key <- format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC")
  }
  run_key <- sanitise_run_key(run_key)
  run_dir <- file.path(output_dir(), "runs", run_key)
  fs::dir_create(run_dir, recurse = TRUE)
  fs::dir_create(file.path(run_dir, "tables"), recurse = TRUE)
  fs::dir_create(file.path(run_dir, "figures"), recurse = TRUE)
  fs::dir_create(file.path(run_dir, "reports"), recurse = TRUE)

  ctx <- list(
    run_key = run_key,
    git_sha = git_sha(),
    root = root,
    run_dir = run_dir,
    manifest_path = file.path(run_dir, "manifest.json"),
    data = list(),
    outputs = character(),
    steps = list(),
    start_time = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    status = "RUNNING"
  )
  write_manifest(ctx, "RUNNING")
  ctx
}

#' Write the manifest
#' @param ctx Run context.
#' @param status Status string.
#' @param error Optional error message (secret-redacted).
#' @export
write_manifest <- function(ctx, status, error = NULL) {
  ctx$status <- status
  finish <- if (status %in% c("SUCCESS", "FAILED", "PARTIAL")) {
    format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  } else {
    NULL
  }
  manifest <- list(
    run_key = ctx$run_key,
    status = status,
    start_time = ctx$start_time,
    finish_time = finish,
    git_sha = ctx$git_sha,
    r_version = paste(R.version$major, R.version$minor, sep = "."),
    steps = ctx$steps,
    outputs = ctx$outputs,
    error = error
  )
  # per-mart row counts / fingerprints if data present
  if (length(ctx$data)) {
    manifest$marts <- lapply(names(ctx$data), function(m) {
      list(mart = m, n_rows = nrow(ctx$data[[m]]))
    })
  }
  jsonlite::write_json(manifest, ctx$manifest_path, auto_unbox = TRUE, pretty = TRUE)
  invisible(ctx)
}
