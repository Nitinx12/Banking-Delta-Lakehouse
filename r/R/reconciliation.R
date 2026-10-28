# Cross-mart reconciliation: marts built from same facts must agree.

#' Reconcile monthly transaction totals against KPI mart
#' @param con DBI connection.
#' @export
reconcile_txns_vs_kpi <- function(con) {
  sql <- "
    SELECT t.month_start,
           SUM(t.total_amount) AS txn_total,
           k.txn_amount AS kpi_total,
           SUM(t.total_amount) - k.txn_amount AS diff
    FROM marts.mart_monthly_transactions t
    JOIN marts.mart_kpi_monthly k ON k.month_start = t.month_start
    GROUP BY t.month_start, k.txn_amount
    ORDER BY t.month_start"
  DBI::dbGetQuery(con, sql)
}

#' Check completeness: no missing months in a date mart
#' @param df data frame with a date column.
#' @param date_col column name.
#' @export
check_completeness <- function(df, date_col) {
  d <- sort(unique(as.Date(df[[date_col]])))
  if (length(d) < 2) return(list(ok = TRUE, missing = as.Date(character())))
  full <- seq(min(d), max(d), by = "month")
  missing <- setdiff(full, d)
  list(ok = length(missing) == 0, missing = missing)
}
