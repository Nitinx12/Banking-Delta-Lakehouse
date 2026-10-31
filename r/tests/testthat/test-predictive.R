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

test_that("fit_fraud_model returns gbm structure", {
  df <- data.frame(
    card_id = 1:100,
    is_fraud = sample(0:1, 100, replace = TRUE),
    amount = rnorm(100),
    hour = sample(0:23, 100, replace = TRUE)
  )
  model <- fit_fraud_model(df, "is_fraud", c("amount", "hour"))
  expect_equal(model$type, "gbm")
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
