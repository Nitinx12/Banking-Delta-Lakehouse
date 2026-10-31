
# Figure generation for the run. Writes PNGs under ctx$run_dir/figures.

#' Generate standard figures for all marts in ctx$data
#' @param ctx Run context (environment).
#' @export
write_figures <- function(ctx) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    bankinganalytics::log_warn("ggplot2 not installed; skipping figures")
    return(invisible(NULL))
  }
  dir.create(file.path(ctx$run_dir, "figures"), showWarnings = FALSE, recursive = TRUE)

  save_plot <- function(name, p) {
    path <- file.path(ctx$run_dir, "figures", paste0(name, ".png"))
    ggplot2::ggsave(path, plot = p, width = 9, height = 5, dpi = 120)
    ctx$outputs <- c(ctx$outputs, file.path("figures", paste0(name, ".png")))
    invisible(path)
  }

  # KPI trend: transaction amount over time
  if ("mart_kpi_monthly" %in% names(ctx$data)) {
    df <- ctx$data$mart_kpi_monthly
    p <- ggplot2::ggplot(df, ggplot2::aes(x = .data$month_start, y = .data$txn_amount)) +  # nolint
      ggplot2::geom_line(colour = "#1f77b4") +
      ggplot2::labs(title = "Monthly transaction amount", x = "Month", y = "Amount")  # nolint
    save_plot("kpi_txn_trend", p)
  }

  # Monthly transactions: total amount by month
  if ("mart_monthly_transactions" %in% names(ctx$data)) {
    df <- ctx$data$mart_monthly_transactions
    agg <- stats::aggregate(total_amount ~ month_start, data = df, FUN = sum)
    p <- ggplot2::ggplot(agg, ggplot2::aes(x = .data$month_start, y = .data$total_amount)) +  # nolint
      ggplot2::geom_line(colour = "#2ca02c") +
      ggplot2::labs(title = "Monthly transactions total amount", x = "Month", y = "Total amount")  # nolint
    save_plot("monthly_txn_volume", p)
  }

  # Card fraud rate by card type
  if ("mart_card_fraud" %in% names(ctx$data)) {
    df <- ctx$data$mart_card_fraud
    agg <- stats::aggregate(fraud_rate_pct ~ card_type, data = df, FUN = mean)
    p <- ggplot2::ggplot(agg, ggplot2::aes(x = .data$card_type, y = .data$fraud_rate_pct)) +  # nolint
      ggplot2::geom_col(fill = "#d62728") +
      ggplot2::labs(title = "Avg fraud rate by card type", x = "Card type", y = "Fraud rate %") +  # nolint
      ggplot2::theme(axis.text.x = ggplot2::element_text(angle = 30, hjust = 1))
    save_plot("fraud_by_card_type", p)
  }

  # Branch performance: accounts per employee (top 15)
  if ("mart_branch_performance" %in% names(ctx$data)) {
    df <- ctx$data$mart_branch_performance
    df <- df[order(-df$accounts_per_employee), ][seq_len(min(15, nrow(df))), ]
    p <- ggplot2::ggplot(df, ggplot2::aes(
      x = stats::reorder(.data$branch_name, .data$accounts_per_employee),  # nolint
      y = .data$accounts_per_employee  # nolint
    )) +
      ggplot2::geom_col(fill = "#9467bd") +
      ggplot2::coord_flip() +
      ggplot2::labs(
        title = "Top branches by accounts per employee",
        x = "Branch",
        y = "Accounts per employee"  # nolint
      )
    save_plot("branch_accounts_per_employee", p)
  }

  # Loan portfolio: loan count by status
  if ("mart_loan_portfolio" %in% names(ctx$data)) {
    df <- ctx$data$mart_loan_portfolio
    agg <- stats::aggregate(loan_count ~ status, data = df, FUN = sum)
    p <- ggplot2::ggplot(agg, ggplot2::aes(x = .data$status, y = .data$loan_count)) +  # nolint
      ggplot2::geom_col(fill = "#8c564b") +
      ggplot2::labs(title = "Loan count by status", x = "Status", y = "Loan count")  # nolint
    save_plot("loan_by_status", p)
  }

  # Support: ticket count by issue type
  if ("mart_support_performance" %in% names(ctx$data)) {
    df <- ctx$data$mart_support_performance
    agg <- stats::aggregate(ticket_count ~ issue_type, data = df, FUN = sum)
    p <- ggplot2::ggplot(agg, ggplot2::aes(
      x = stats::reorder(.data$issue_type, -.data$ticket_count),  # nolint
      y = .data$ticket_count  # nolint
    )) +
      ggplot2::geom_col(fill = "#e377c2") +
      ggplot2::coord_flip() +
      ggplot2::labs(title = "Tickets by issue type", x = "Issue type", y = "Tickets")  # nolint
    save_plot("support_by_issue", p)
  }

  invisible(NULL)
}
