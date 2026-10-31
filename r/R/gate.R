# The gate: refuse to analyse marts that are empty, unreadable or stale.

.read_sql <- function(name) {
  path <- system.file("sql", name, package = "bankinganalytics")
  if (!nzchar(path)) stop("SQL file not found: ", name, call. = FALSE)
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

.audit_problems <- function(con) {
  problems <- character()

  dq <- tryCatch(DBI::dbGetQuery(con, .read_sql("mart_dq_status.sql")),
                 error = function(e) e)
  if (inherits(dq, "error")) {
    problems <- c(problems, sprintf("audit DQ unreadable: %s", conditionMessage(dq)))
  } else if (nrow(dq) == 0L || is.na(dq$checks[[1]]) || dq$checks[[1]] == 0) {
    problems <- c(problems, "no marts DQ results in audit.v_dq_latest")
  } else if (!is.na(dq$failures[[1]]) && dq$failures[[1]] > 0) {
    problems <- c(problems, sprintf("%d marts DQ check(s) failed in audit.v_dq_latest",
                                    as.integer(dq$failures[[1]])))
  }

  run <- tryCatch(DBI::dbGetQuery(con, .read_sql("pipeline_run_status.sql")),
                  error = function(e) e)
  if (inherits(run, "error")) {
    problems <- c(problems, sprintf("audit pipeline run unreadable: %s", conditionMessage(run)))
  } else if (nrow(run) == 0L) {
    problems <- c(problems, "no rows in audit.pipeline_runs")
  } else if (!run$status[[1]] %in% c("SUCCESS", "PARTIAL")) {
    problems <- c(problems, sprintf("latest pipeline run is %s", run$status[[1]]))
  } else if (run$status[[1]] == "PARTIAL") {
    if (is.na(run$marts_runs[[1]]) || run$marts_runs[[1]] == 0) {
      problems <- c(problems, "latest pipeline run is PARTIAL with no marts table runs")
    } else if (!is.na(run$marts_failed[[1]]) && run$marts_failed[[1]] > 0) {
      problems <- c(problems, sprintf(
        "latest PARTIAL pipeline run has %d failed marts table run(s)",
        as.integer(run$marts_failed[[1]])
      ))
    }
  }

  problems
}

#' Stop unless every configured mart is readable, non-empty and fresh enough
#' @param con A DBI connection.
#' @param cfg Parsed analysis.yml.
#' @param now Reference instant (injectable for tests).
#' @export
assert_marts_ready <- function(con, cfg = cfg_analysis(), now = Sys.time()) {
  problems <- character()
  default_age <- cfg$gate$default_max_age_hours %||% 30

  for (mart in names(cfg$marts)) {
    spec  <- cfg$marts[[mart]]
    col   <- spec$freshness_col
    stats <- tryCatch(mart_stats(con, mart, col), error = function(e) e)

    if (inherits(stats, "error")) {
      problems <- c(problems, sprintf("%s unreadable: %s", mart, conditionMessage(stats)))
      next
    }
    if (is.na(stats$n) || stats$n == 0) {
      problems <- c(problems, sprintf("%s is empty", mart))
      next
    }
    if (is.null(col)) {
      log_warn("no freshness_col configured for {mart}; only checking it is non-empty")
      next
    }

    max_age <- spec$max_age_hours %||% default_age
    age_h <- as.numeric(difftime(now, as.POSIXct(stats$latest, tz = "UTC"), units = "hours"))
    if (is.na(age_h) || age_h > max_age) {
      problems <- c(problems, sprintf("%s is stale (%s h old, limit %s h)",
                                      mart, format(round(age_h, 1)), max_age))
    }
  }

  if (isTRUE(cfg$gate$check_audit %||% TRUE)) {
    problems <- c(problems, .audit_problems(con))
  }

  if (length(problems)) {
    stop("Marts not ready:\n - ", paste(problems, collapse = "\n - "), call. = FALSE)
  }
  invisible(TRUE)
}
