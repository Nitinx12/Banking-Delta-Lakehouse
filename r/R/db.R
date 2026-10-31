# Warehouse access: read-only, UTC, time-boxed.

#' Open a read-only warehouse connection
#' @export
pg_connect <- function() {
  host     <- bankinganalytics::cfg_env("R_PG_HOST")
  port     <- as.integer(bankinganalytics::cfg_env("R_PG_PORT", "5432"))
  dbname   <- bankinganalytics::cfg_env("R_PG_DATABASE", "banking_delta")
  user     <- bankinganalytics::cfg_env("R_PG_USER")
  password <- bankinganalytics::cfg_env("R_PG_PASSWORD")
  sslmode  <- bankinganalytics::cfg_env("R_PG_SSLMODE", "prefer")

  con <- DBI::dbConnect(
    RPostgres::Postgres(),
    host             = host,
    port             = port,
    dbname           = dbname,
    user             = user,
    password         = password,
    sslmode          = sslmode,
    connect_timeout  = 10,
    application_name = "bankinganalytics-r",
    timezone         = "UTC",
    timezone_out     = "UTC",
    bigint           = "numeric"
  )
  # Do not leak the connection if one of the session settings fails.
  ok <- FALSE
  on.exit(if (!ok) DBI::dbDisconnect(con), add = TRUE)
  DBI::dbExecute(con, "SET default_transaction_read_only = on")
  DBI::dbExecute(con, "SET statement_timeout = '120s'")
  ok <- TRUE
  con
}

#' Run `fn(con)` with a connection that is always closed
#' @param fn A function taking a DBI connection.
#' @export
with_pg <- function(fn) {
  con <- pg_connect()
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  fn(con)
}
