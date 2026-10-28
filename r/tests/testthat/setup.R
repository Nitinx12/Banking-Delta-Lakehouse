# Hermetic guard: unset DB env vars so accidental pg_connect() fails fast.
withr::local_envvar(
  c(R_PG_HOST = NA, R_PG_USER = NA, R_PG_PASSWORD = NA, R_PG_DATABASE = NA),
  .local_envir = teardown_env()
)

options(bankinganalytics.root = normalizePath("..", mustWork = FALSE))
