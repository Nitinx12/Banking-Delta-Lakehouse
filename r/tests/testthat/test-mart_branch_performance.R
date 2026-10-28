test_that("funnel_limits widen with smaller n", {
  small <- bankinganalytics::funnel_limits(10, 0.1)
  large <- bankinganalytics::funnel_limits(1000, 0.1)
  expect_true((small$upper - small$lower) > (large$upper - large$lower))
})

test_that("robust_z flags a far outlier", {
  z <- bankinganalytics::robust_z(c(1, 2, 3, 4, 100))
  expect_true(abs(z[5]) > 3)
  expect_true(all(abs(z[1:4]) < 3))
})

test_that("robust_z returns NA when MAD is zero", {
  z <- bankinganalytics::robust_z(rep(5, 5))
  expect_true(all(is.na(z)))
})

test_that("shrink_rank shrinks small-n rates toward the prior", {
  df <- data.frame(
    branch = c("big", "small"),
    k = c(50, 1),
    n = c(100, 2)
  )
  out <- bankinganalytics::shrink_rank(df, "branch", "k", "n")
  expect_true(out$shrunk_rate[out$id == "small"] > out$raw_rate[out$id == "small"])
  expect_equal(out$rank[1], 1)
})

test_that("peer_percentile ranks within peer group", {
  df <- data.frame(
    id = c("a", "b", "c"),
    v = c(10, 20, 30),
    peer = c("x", "x", "y")
  )
  out <- bankinganalytics::peer_percentile(df, "id", "v", "peer")
  expect_equal(out$percentile[out$id == "b"], 100)
  expect_equal(out$percentile[out$id == "c"], 100)
})
