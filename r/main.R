# ENTRY POINT: preflight -> gate -> extract -> profile -> report

# Resolve project root whether run from r/ or the repo root.
root <- getwd()
if (!file.exists(file.path(root, "DESCRIPTION")) && file.exists(file.path(root, "r", "DESCRIPTION"))) {
  root <- file.path(root, "r")
}
options(bankinganalytics.root = normalizePath(root, mustWork = FALSE))
setwd(root)

# Dev convenience: load r/.env.r into the environment if present.
env_file <- file.path(root, ".env.r")
if (file.exists(env_file)) {
  lines <- readLines(env_file, warn = FALSE)
  for (ln in lines) {
    ln <- trimws(ln)
    if (!nzchar(ln) || startsWith(ln, "#")) next
    parts <- strsplit(ln, "=", fixed = TRUE)[[1]]
    if (length(parts) >= 2) {
      key <- trimws(parts[1])
      val <- trimws(paste(parts[-1], collapse = "="))
      if (nzchar(key) && !nzchar(Sys.getenv(key, unset = ""))) {
        do.call(Sys.setenv, setNames(list(val), key))
      }
    }
  }
}

# --- argument parsing ---
args <- commandArgs(trailingOnly = TRUE)
list_only <- "--list" %in% args
keep_going <- "--keep-going" %in% args
skip_report <- "--skip-report" %in% args
only <- NULL
run_key <- NULL
for (a in args) {
  if (startsWith(a, "--only=")) only <- strsplit(sub("^--only=", "", a), ",")[[1]]
  if (startsWith(a, "--run-key=")) run_key <- sub("^--run-key=", "", a)
}

STEP_INFO <- list(
  preflight      = "env vars, packages, config, writable output folder",
  gate           = "assert_marts_ready() on every configured mart",
  extract        = "mart_fingerprint() + read_mart() + assert_contract() per mart",
  profile        = "profile_mart() -> tables/profile_<mart>.csv",
  figures        = "standard figures -> figures/*.png",
  reconciliation = "cross-mart reconciliation + completeness",
  monitoring     = "control charts + PSI flags",
  report         = "renders analyses/*/index.qmd if any exist"
)
STEP_ORDER <- names(STEP_INFO)

if (list_only) {
  for (s in STEP_ORDER) cat(sprintf("%-10s %s\n", s, STEP_INFO[[s]]))
  quit(status = 0)
}

# --- package loading ---
if (requireNamespace("pkgload", quietly = TRUE) && dir.exists("R")) {
  pkgload::load_all(".")
} else {
  suppressPackageStartupMessages(library(bankinganalytics))
}

suppressPackageStartupMessages({
  library(dplyr)
})

cfg <- bankinganalytics::cfg_analysis()
contracts <- bankinganalytics::cfg_contracts()

ctx <- list2env(bankinganalytics::run_context(run_key), parent = emptyenv())

# dependency check: profile needs extract in same invocation
if (!is.null(only) && "profile" %in% only && !"extract" %in% only) {
  cat("profile requires extract in the same invocation\n")
  quit(status = 64)
}
if (is.null(only)) only <- STEP_ORDER
# canonical order
only <- intersect(STEP_ORDER, only)

run_step <- function(name) {
  t0 <- Sys.time()
  res <- tryCatch({
    do.call(paste0("step_", name), list(ctx))
    list(status = "SUCCESS", seconds = as.numeric(difftime(Sys.time(), t0, units = "secs")), error = NULL)
  }, error = function(e) {
    list(status = "FAILED", seconds = as.numeric(difftime(Sys.time(), t0, units = "secs")), error = conditionMessage(e))
  })
  ctx$steps[[name]] <- res
  bankinganalytics::write_manifest(ctx, if (res$status == "FAILED") "RUNNING" else "RUNNING")
  res
}

step_preflight <- function(ctx) {
  # env vars
  bankinganalytics::cfg_env("R_PG_HOST")
  bankinganalytics::cfg_env("R_PG_USER")
  bankinganalytics::cfg_env("R_PG_PASSWORD")
  # config
  bankinganalytics::cfg_analysis()
  bankinganalytics::cfg_contracts()
  # writable output
  dir.create(bankinganalytics::output_dir(), showWarnings = FALSE, recursive = TRUE)
  if (!dir.exists(bankinganalytics::output_dir())) stop("output dir not writable", call. = FALSE)
  invisible(TRUE)
}

step_gate <- function(ctx) {
  bankinganalytics::with_pg(function(con) bankinganalytics::assert_marts_ready(con, cfg))
}

step_extract <- function(ctx) {
  for (mart in names(cfg$marts)) {
    spec <- cfg$marts[[mart]]
    col <- spec$freshness_col
    token <- bankinganalytics::mart_fingerprint(mart, col)
    df <- bankinganalytics::read_mart(mart, token)
    cspec <- contracts[[mart]]
    bankinganalytics::assert_contract(df, mart, cspec)
    ctx$data[[mart]] <- df
  }
  invisible(TRUE)
}

step_profile <- function(ctx) {
  if (length(ctx$data) == 0) stop("no mart data in memory", call. = FALSE)
  for (mart in names(ctx$data)) {
    prof <- bankinganalytics::profile_mart(ctx$data[[mart]], mart)
    bankinganalytics::write_table(ctx, paste0("profile_", mart), prof)
  }
  invisible(TRUE)
}

step_figures <- function(ctx) {
  if (length(ctx$data) == 0) stop("no mart data in memory", call. = FALSE)
  bankinganalytics::write_figures(ctx)
  invisible(TRUE)
}

step_reconciliation <- function(ctx) {
  if (length(ctx$data) == 0) stop("no mart data in memory", call. = FALSE)
  rec <- bankinganalytics::with_pg(bankinganalytics::reconcile_txns_vs_kpi)
  bankinganalytics::write_table(ctx, "reconciliation_txns_vs_kpi", rec)
  # completeness checks for date marts
  comp_rows <- list()
  for (mart in c("mart_kpi_monthly", "mart_monthly_transactions", "mart_card_fraud", "mart_support_performance")) {
    if (mart %in% names(ctx$data)) {
      dc <- if (mart == "mart_support_performance") "month_opened" else "month_start"
      res <- bankinganalytics::check_completeness(ctx$data[[mart]], dc)
      comp_rows[[mart]] <- data.frame(mart = mart, complete = res$ok, n_missing = length(res$missing))
    }
  }
  if (length(comp_rows)) {
    comp <- do.call(rbind, comp_rows)
    bankinganalytics::write_table(ctx, "completeness", comp)
  }
  invisible(TRUE)
}

step_monitoring <- function(ctx) {
  if (length(ctx$data) == 0) stop("no mart data in memory", call. = FALSE)
  # control chart for KPI txn_amount
  if ("mart_kpi_monthly" %in% names(ctx$data)) {
    x <- ctx$data$mart_kpi_monthly$txn_amount
    lim <- bankinganalytics::individuals_limits(x)
    flags <- bankinganalytics::control_flags(x, lim)
    out <- data.frame(
      month_start = ctx$data$mart_kpi_monthly$month_start,
      txn_amount = x,
      ucl = lim$ucl, lcl = lim$lcl, center = lim$center,
      out_of_control = flags
    )
    bankinganalytics::write_table(ctx, "control_chart_kpi", out)
  }
  invisible(TRUE)
}

step_report <- function(ctx) {
  if (skip_report) return(invisible(TRUE))
  qmds <- list.files("analyses", pattern = "index\\.qmd", recursive = TRUE, full.names = TRUE)
  if (length(qmds) == 0) return(invisible(TRUE))
  if (!requireNamespace("quarto", quietly = TRUE)) {
    stop("quarto package missing", call. = FALSE)
  }
  for (q in qmds) {
    quarto::quarto_render(q, quarto_args = c("--output-dir", file.path(ctx$run_dir, "reports")), quiet = TRUE)
  }
  invisible(TRUE)
}

# --- run ---
failed <- FALSE
partial <- FALSE
for (s in only) {
  r <- run_step(s)
  if (r$status == "FAILED") {
    failed <- TRUE
    cat(sprintf("step %s failed: %s\n", s, r$error))
    if (!keep_going) break
    partial <- TRUE
  }
}

# prune old runs
retention <- cfg$retention_days %||% 30
if (!is.null(retention)) {
  runs_dir <- file.path(bankinganalytics::output_dir(), "runs")
  if (dir.exists(runs_dir)) {
    dirs <- list.dirs(runs_dir, full.names = TRUE, recursive = FALSE)
    for (d in dirs) {
      if (normalizePath(d) == normalizePath(ctx$run_dir)) next
      info <- file.info(d)
      age <- as.numeric(difftime(Sys.time(), info$mtime, units = "days"))
      if (!is.na(age) && age > retention) unlink(d, recursive = TRUE)
    }
  }
}

if (failed && !keep_going) {
  bankinganalytics::write_manifest(ctx, "FAILED", error = ctx$steps[[tail(only, 1)]]$error)
  quit(status = 1)
}
if (partial) {
  bankinganalytics::write_manifest(ctx, "PARTIAL")
  quit(status = 2)
}
bankinganalytics::write_manifest(ctx, "SUCCESS")
quit(status = 0)
