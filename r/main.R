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
  analyses       = "Tier 1 descriptive tables per mart",
  forecast       = "Tier 3 forecasts + backtests for KPIs",
  predict        = "Tier 3 Predictive risk scores (PD, Fraud, Attrition)",
  targets        = "Run targets dependency graph (_targets.R)",
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

step_analyses <- function(ctx) {
  if (length(ctx$data) == 0) stop("no mart data in memory", call. = FALSE)

  if ("mart_kpi_monthly" %in% names(ctx$data)) {
    df <- ctx$data$mart_kpi_monthly
    g <- bankinganalytics::kpi_growth(df, "month_start", "txn_amount")
    bankinganalytics::write_table(ctx, "kpi_growth_txn_amount", g)
    sp <- bankinganalytics::kpi_seasonal_profile(df, "month_start", "txn_amount")
    bankinganalytics::write_table(ctx, "kpi_seasonal_txn_amount", sp)
    
    # Structural breaks (Tier 2 diagnostic)
    if (nrow(df) >= 12) {
      breaks <- bankinganalytics::kpi_break_flags(df$txn_amount)
      out_breaks <- data.frame(month_start = df$month_start, txn_amount = df$txn_amount, break_flag = breaks)
      bankinganalytics::write_table(ctx, "kpi_structural_breaks", out_breaks)
    }
  }

  if ("mart_monthly_transactions" %in% names(ctx$data)) {
    df <- ctx$data$mart_monthly_transactions
    tot <- bankinganalytics::txn_monthly_totals(df, "month_start", "total_amount", "txn_count")
    bankinganalytics::write_table(ctx, "txn_monthly_totals", tot)
    if ("channel" %in% names(df)) {
      mix <- bankinganalytics::txn_mix_share(df, "month_start", "channel", "total_amount")
      bankinganalytics::write_table(ctx, "txn_mix_channel", mix)
    }
    if (nrow(tot) >= 6) {
      anom <- bankinganalytics::txn_anomaly_flags(tot, "month_start", "total_amount")
      bankinganalytics::write_table(ctx, "txn_anomaly_flags", anom)
    }
    
    # CAGR (Tier 1 Descriptive)
    if (nrow(tot) >= 2) {
      start_val <- tot$total_amount[1]
      end_val <- tot$total_amount[nrow(tot)]
      # Approximate years
      years <- as.numeric(difftime(max(tot$month_start), min(tot$month_start), units = "days")) / 365.25
      if (start_val > 0 && end_val > 0 && years > 0) {
        cagr_res <- bankinganalytics::txn_cagr(start_val, end_val, years)
        bankinganalytics::write_table(ctx, "txn_cagr_total_amount", data.frame(cagr = cagr_res$cagr, years = years))
      }
    }
  }

  if ("mart_customer_360" %in% names(ctx$data)) {
    df <- ctx$data$mart_customer_360
    if ("txn_amount" %in% names(df)) {
      conc <- bankinganalytics::concentration(df$txn_amount)
      bankinganalytics::write_table(ctx, "customer_concentration", data.frame(
        gini = conc$gini, top_decile_share = conc$top_decile_share
      ))
    }
    if (all(c("last_txn_date", "txn_count", "txn_amount") %in% names(df))) {
      recency <- as.numeric(as.Date(Sys.Date()) - as.Date(df$last_txn_date))
      rfm <- bankinganalytics::rfm_score(
        data.frame(recency = recency, frequency = df$txn_count, monetary = df$txn_amount),
        "recency", "frequency", "monetary", n = 5
      )
      seg_df <- data.frame(rfm = rfm$rfm, txn_amount = df$txn_amount)
      prof <- bankinganalytics::segment_profile(seg_df, "rfm", "txn_amount")
      bankinganalytics::write_table(ctx, "customer_rfm_profile", prof)
    }
  }

  if ("mart_loan_portfolio" %in% names(ctx$data)) {
    df <- ctx$data$mart_loan_portfolio
    q <- bankinganalytics::portfolio_quality(df, "loan_count", "total_loan_amount")
    bankinganalytics::write_table(ctx, "loan_portfolio_quality", as.data.frame(q))
    if ("loan_type" %in% names(df)) {
      conc <- bankinganalytics::concentration_by(df, "loan_type", "total_loan_amount")
      bankinganalytics::write_table(ctx, "loan_concentration_by_type", conc$table)
    }
  }

  if ("mart_card_fraud" %in% names(ctx$data)) {
    df <- ctx$data$mart_card_fraud
    if ("card_type" %in% names(df) &&
        all(c("fraud_txn_count", "txn_count") %in% names(df))) {
      prof <- bankinganalytics::fraud_rate_profile(df, "card_type", "fraud_txn_count", "txn_count")
      bankinganalytics::write_table(ctx, "fraud_rate_by_card_type", prof)
    }
    
    # Performance metrics (Tier 2 diagnostic)
    if ("is_fraud" %in% names(df)) {
      # We need a score for these metrics. Use the predicted scores if available, 
      # otherwise we just skip or use a placeholder.
      # Since this is step_analyses, we might not have scores yet unless we call predict first.
      # For now, we check if a 'fraud_score' column was already added to the mart data.
      if ("fraud_score" %in% names(df)) {
        ap <- bankinganalytics::avg_precision(df$fraud_score, df$is_fraud)
        p10 <- bankinganalytics::precision_at_k(df$fraud_score, df$is_fraud, k = 10)
        bankinganalytics::write_table(ctx, "fraud_model_performance", data.frame(avg_precision = ap, precision_at_10 = p10))
      }
    }
  }

  if ("mart_branch_performance" %in% names(ctx$data)) {
    df <- ctx$data$mart_branch_performance
    if (all(c("branch_key", "total_accounts", "active_accounts") %in% names(df))) {
      rank <- bankinganalytics::shrink_rank(df, "branch_key", "active_accounts", "total_accounts")
      bankinganalytics::write_table(ctx, "branch_shrink_rank", rank)
    }
  }

  if ("mart_support_performance" %in% names(ctx$data)) {
    df <- ctx$data$mart_support_performance
    if (all(c("month_opened", "resolved_count", "ticket_count") %in% names(df))) {
      trend <- bankinganalytics::sla_trend(df, "month_opened", "resolved_count", "ticket_count")
      bankinganalytics::write_table(ctx, "support_sla_trend", trend)
    }
  }

  # Variance bridges are configured in analysis.yml, never hard-coded here.
  for (b in cfg$variance_bridges %||% list()) {
    if (!b$mart %in% names(ctx$data)) next
    df <- ctx$data[[b$mart]]
    if (!all(c(b$value_col, b$count_col) %in% names(df))) {
      bankinganalytics::log_warn(sprintf(
        "variance bridge %s skipped: missing %s or %s in %s",
        b$label, b$value_col, b$count_col, b$mart
      ))
      next
    }
    if (!is.null(b$date_col) && b$date_col %in% names(df)) {
      df <- df[order(df[[b$date_col]]), , drop = FALSE]
    }
    vb <- bankinganalytics::kpi_variance_bridge(df, b$value_col, b$count_col, b$date_col)
    bankinganalytics::write_table(ctx, paste0("variance_bridge_", b$label), vb)
  }

  invisible(TRUE)
}

step_forecast <- function(ctx) {
  if (length(ctx$data) == 0) stop("no mart data in memory", call. = FALSE)

  # Forecasts for mart_kpi_monthly (txn_amount)
  if ("mart_kpi_monthly" %in% names(ctx$data)) {
    df <- ctx$data$mart_kpi_monthly
    
    # 1. Backtest (T3 rigor)
    if (nrow(df) >= 30) {
      bt <- bankinganalytics::backtest_forecast(df, "month_start", "txn_amount")
      bankinganalytics::write_table(ctx, "forecast_backtest_kpi_txn", bt)
    }

    # 2. Future projection
    proj <- bankinganalytics::forecast_future(df, "month_start", "txn_amount", h = 6)
    bankinganalytics::write_table(ctx, "forecast_future_kpi_txn", proj)
  }

  # Forecasts for mart_monthly_transactions (total_amount)
  if ("mart_monthly_transactions" %in% names(ctx$data)) {
    df <- ctx$data$mart_monthly_transactions
    
    if (nrow(df) >= 30) {
      bt <- bankinganalytics::backtest_forecast(df, "month_start", "total_amount")
      bankinganalytics::write_table(ctx, "forecast_backtest_txn_total", bt)
    }
    
    proj <- bankinganalytics::forecast_future(df, "month_start", "total_amount", h = 6)
    bankinganalytics::write_table(ctx, "forecast_future_txn_total", proj)
  }

  invisible(TRUE)
}

step_predict <- function(ctx) {
  if (length(ctx$data) == 0) stop("no mart data in memory", call. = FALSE)

  # 1. PD Scorecard (Loan Portfolio)
  if ("mart_loan_portfolio" %in% names(ctx$data)) {
    df <- ctx$data$mart_loan_portfolio
    if ("is_default" %in% names(df)) {
      # Identify features automatically from the mart or config
      features <- setdiff(names(df), c("loan_id", "is_default", "month_start"))
      model <- bankinganalytics::fit_pd_scorecard(df, "is_default", features)
      scores <- bankinganalytics::predict_risk_scores(model, df)
      
      res <- data.frame(loan_id = df$loan_id, pd_score = scores)
      bankinganalytics::write_table(ctx, "predict_pd_scores", res)
    }
  }

  # 2. Fraud Detection (Card Fraud)
  if ("mart_card_fraud" %in% names(ctx$data)) {
    df <- ctx$data$mart_card_fraud
    if ("is_fraud" %in% names(df)) {
      features <- setdiff(names(df), c("card_id", "is_fraud", "month_start"))
      model <- bankinganalytics::fit_fraud_model(df, "is_fraud", features)
      scores <- bankinganalytics::predict_risk_scores(model, df)
      
      res <- data.frame(card_id = df$card_id, fraud_score = scores)
      bankinganalytics::write_table(ctx, "predict_fraud_scores", res)
    }
  }

  # 3. Attrition Risk (Customer 360)
  if ("mart_customer_360" %in% names(ctx$data)) {
    df <- ctx$data$mart_customer_360
    if ("is_attrited" %in% names(df)) {
      features <- setdiff(names(df), c("customer_id", "is_attrited", "month_start"))
      model <- bankinganalytics::fit_attrition_model(df, "is_attrited", features)
      scores <- bankinganalytics::predict_risk_scores(model, df)
      
      res <- data.frame(customer_id = df$customer_id, attrition_score = scores)
      bankinganalytics::write_table(ctx, "predict_attrition_scores", res)
    }
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
  Sys.setenv(BANKING_RUN_DIR = ctx$run_dir)
  on.exit(Sys.unsetenv("BANKING_RUN_DIR"), add = TRUE)
  for (q in qmds) {
    quarto::quarto_render(q, quarto_args = c("--output-dir", file.path(ctx$run_dir, "reports")), quiet = TRUE)
  }
  invisible(TRUE)
}

# --- run ---
failed <- FALSE
partial <- FALSE
for (s in only) {
  if (s == "targets") {
    # Delegate to the targets dependency graph
    r <- tryCatch({
      targets::tar_make()
      list(status = "SUCCESS", seconds = 0, error = NULL)
    }, error = function(e) {
      list(status = "FAILED", seconds = 0, error = conditionMessage(e))
    })
  } else {
    r <- run_step(s)
  }
  
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
