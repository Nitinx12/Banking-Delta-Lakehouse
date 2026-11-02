# Tests for predictive modeling modules.
library(testthat)
library(bankinganalytics)

test_that("fit_pd_scorecard returns expected structure", {
  df <- data.frame(
    loan_id = 1:100,
    is_default = sample(0:1, 100, replace = TRUE),
    feature1 = rnorm(100),
    feature2 = rnorm(100)
  )
  model <- fit_pd_scorecard(df, "is_default", c("feature1", "feature2"))
  expect_type(model, "list")
  expect_equal(model$type, "logistic")
  expect_true(!is.null(model$model))
})

test_that("predict_risk_scores returns numeric vector", {
  df <- data.frame(
    loan_id = 1:100,
    is_default = sample(0:1, 100, replace = TRUE),
    feature1 = rnorm(100),
    feature2 = rnorm(100)
  )
  model <- fit_pd_scorecard(df, "is_default", c("feature1", "feature2"))
  scores <- predict_risk_scores(model, df)
  expect_type(scores, "double")
  expect_equal(length(scores), 100)
  expect_true(all(scores >= 0 & scores <= 1))
})

test_that("PD scores use the positive class and expose WoE/IV", {
  df <- data.frame(
    is_default = rep(c(0, 1), each = 50),
    feature1 = c(rnorm(50, 0), rnorm(50, 2)),
    feature2 = c(rnorm(50, 0), rnorm(50, 1))
  )
  model <- fit_pd_scorecard(df, "is_default", c("feature1", "feature2"))
  scores <- predict_risk_scores(model, df)
  expect_equal(model$positive, "1")
  expect_true(all(c("feature1", "feature2") %in% names(model$iv)))
  expect_true(all(model$iv >= 0))
  expect_gt(mean(scores[df$is_default == 1]), mean(scores[df$is_default == 0]))
})

test_that("PD positive class can be named explicitly", {
  df <- data.frame(
    is_default = factor(rep(c("good", "bad"), each = 50), levels = c("bad", "good")),
    feature1 = c(rnorm(50, 0), rnorm(50, 2))
  )
  model <- fit_pd_scorecard(df, "is_default", "feature1", positive = "good")
  scores <- predict_risk_scores(model, df)
  expect_equal(model$positive, "good")
  expect_gt(mean(scores[df$is_default == "good"]), mean(scores[df$is_default == "bad"]))
})

test_that("fit_fraud_model fits the WoE logistic it reports", {
  df <- data.frame(
    card_id = 1:100,
    is_fraud = sample(0:1, 100, replace = TRUE),
    amount = rnorm(100),
    hour = sample(0:23, 100, replace = TRUE)
  )
  model <- fit_fraud_model(df, "is_fraud", c("amount", "hour"))
  expect_equal(model$type, "logistic")
  expect_s3_class(model$model, "glm")
})

test_that("fit_attrition_model returns logistic structure", {
  df <- data.frame(
    customer_id = 1:100,
    is_attrited = sample(0:1, 100, replace = TRUE),
    tenure = rnorm(100)
  )
  model <- fit_attrition_model(df, "is_attrited", "tenure")
  expect_equal(model$type, "logistic")
})

test_that("time_split trains on the past and evaluates on the future", {
  df <- data.frame(month_start = as.Date("2020-01-01") + 0:9, v = rnorm(10))
  sp <- bankinganalytics::time_split(df, "month_start", 0.8)
  expect_equal(nrow(sp$train), 8)
  expect_equal(nrow(sp$test), 2)
  expect_true(max(sp$train$month_start) < min(sp$test$month_start))
  expect_equal(sp$cutoff, as.Date("2020-01-08"))
  expect_setequal(c(sp$train_idx, sp$test_idx), 1:10)
})

test_that("time_split rejects splits it cannot make honestly", {
  single <- data.frame(d = as.Date("2020-01-01"))
  expect_error(bankinganalytics::time_split(single, "d"), "single distinct")
  df <- data.frame(d = as.Date("2020-01-01") + 0:9, x = 1:10)
  expect_error(bankinganalytics::time_split(df, "nope"), "not found")
  expect_error(bankinganalytics::time_split(df, "d", 0), "between 0 and 1")
  expect_error(bankinganalytics::time_split(df, "d", 0.01), "empty side")
})

test_that("binary_metrics pairs ranking metrics with the base rate", {
  scores <- c(0.9, 0.8, 0.3, 0.2, 0.7, 0.1)
  labels <- c(1, 1, 0, 0, 0, 1)
  m <- bankinganalytics::binary_metrics(scores, labels, k = 2)
  expect_equal(m$n, 6)
  expect_equal(m$positives, 3)
  expect_equal(m$base_rate, 0.5)
  expect_equal(m$precision_at_k, 1)
  expect_gt(m$avg_precision, m$base_rate)
  expect_error(bankinganalytics::binary_metrics(scores, labels[-1]), "same length")
})