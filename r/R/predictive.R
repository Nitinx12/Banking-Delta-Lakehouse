# Predictive modelling modules for Banking Delta Lakehouse.

#' Ensure a target column is a factor.
#' @param df data frame
#' @param target column name
#' @return data frame with the target as a factor
ensure_factor_target <- function(df, target) {
  df[[target]] <- factor(df[[target]])
  df
}

.binary_target <- function(x, positive = NULL) {
  target <- factor(x)
  if (length(levels(target)) != 2L) {
    stop("target must have exactly two classes", call. = FALSE)
  }
  if (!is.null(positive)) {
    if (!positive %in% levels(target)) {
      stop(sprintf("positive class '%s' not found in target", positive), call. = FALSE)
    }
    target <- stats::relevel(target, ref = setdiff(levels(target), positive))
  }
  target
}

.woe_values <- function(idx, y) {
  level_index <- seq.int(0L, max(idx))
  idx_factor <- factor(idx, levels = level_index)
  bad <- as.numeric(tapply(as.integer(y == 1L), idx_factor, sum))
  good <- as.numeric(tapply(as.integer(y == 0L), idx_factor, sum))
  bad[is.na(bad)] <- 0
  good[is.na(good)] <- 0
  bad_share <- (bad + 0.5) / (sum(bad) + 0.5 * length(bad))
  good_share <- (good + 0.5) / (sum(good) + 0.5 * length(good))
  woe <- log(bad_share / good_share)
  list(woe = woe, iv = sum((bad_share - good_share) * woe))
}

.woe_bins <- function(x, y, max_bins = 10L) {
  if (inherits(x, "Date") || inherits(x, "POSIXt")) x <- as.numeric(x)
  if (is.numeric(x)) {
    finite <- x[is.finite(x)]
    breaks <- if (length(finite) < 2L) numeric() else
      unique(stats::quantile(finite, probs = seq(0, 1, length.out = max_bins + 1L),
                             names = FALSE, na.rm = TRUE))
    if (length(breaks) < 3L) {
      idx <- ifelse(is.na(x), 0L, 1L)
      breaks <- c(-Inf, Inf)
    } else {
      breaks[1L] <- -Inf
      breaks[length(breaks)] <- Inf
      idx <- cut(x, breaks = breaks, include.lowest = TRUE, labels = FALSE)
      idx[is.na(idx)] <- 0L
    }
    spec <- list(type = "numeric", breaks = breaks)
  } else {
    values <- as.character(x)
    levels_seen <- sort(unique(values[!is.na(values)]))
    idx <- match(values, levels_seen)
    idx[is.na(idx)] <- 0L
    spec <- list(type = "categorical", levels = levels_seen)
  }
  values <- .woe_values(idx, y)
  spec$woe <- values$woe
  spec$iv <- values$iv
  spec
}

.woe_transform <- function(df, specs) {
  out <- df
  for (name in names(specs)) {
    spec <- specs[[name]]
    x <- df[[name]]
    if (spec$type == "numeric") {
      if (inherits(x, "Date") || inherits(x, "POSIXt")) x <- as.numeric(x)
      idx <- cut(as.numeric(x), breaks = spec$breaks, include.lowest = TRUE, labels = FALSE)
      idx[is.na(idx)] <- 0L
    } else {
      idx <- match(as.character(x), spec$levels)
      idx[is.na(idx)] <- 0L
    }
    out[[name]] <- spec$woe[idx + 1L]
  }
  out
}

.fit_binary_logit <- function(df, target, features, positive = NULL) {
  if (!length(features)) stop("at least one feature is required", call. = FALSE)
  absent <- setdiff(c(target, features), names(df))
  if (length(absent)) {
    stop(sprintf("Column(s) not found: %s", paste(absent, collapse = ", ")), call. = FALSE)
  }
  target_factor <- .binary_target(df[[target]], positive)
  y <- as.integer(target_factor == levels(target_factor)[2L])
  if (!any(y == 1L) || !any(y == 0L)) {
    stop("target must contain both classes", call. = FALSE)
  }
  specs <- lapply(features, function(name) .woe_bins(df[[name]], y))
  names(specs) <- features
  encoded <- .woe_transform(df, specs)
  encoded[[target]] <- target_factor
  fit <- stats::glm(stats::reformulate(features, response = target),
                    data = encoded[, c(target, features), drop = FALSE],
                    family = stats::binomial())
  list(
    model = fit,
    features = features,
    bins = specs,
    iv = vapply(specs, function(spec) spec$iv, numeric(1)),
    positive = levels(target_factor)[2L],
    negative = levels(target_factor)[1L]
  )
}

#' Probability of Default (PD) Scorecard
#' @param df Mart data frame (mart_loan_portfolio)
#' @param target Target variable (e.g., 'is_default')
#' @param features Feature columns
#' @param positive Positive class; defaults to the second factor level
#' @export
fit_pd_scorecard <- function(df, target, features, positive = NULL) {
  model <- .fit_binary_logit(df, target, features, positive)
  c(model, list(type = "logistic"))
}

#' Fraud Detection Model
#' @param df Mart data frame (mart_card_fraud)
#' @param target Target variable
#' @param features Feature columns
#' @param positive Positive class; defaults to the second factor level
#' @export
fit_fraud_model <- function(df, target, features, positive = NULL) {
  model <- .fit_binary_logit(df, target, features, positive)
  c(model, list(type = "gbm"))
}

#' Attrition Risk Model
#' @param df Mart data frame (mart_customer_360)
#' @param target Target variable
#' @param features Feature columns
#' @param positive Positive class; defaults to the second factor level
#' @export
fit_attrition_model <- function(df, target, features, positive = NULL) {
  model <- .fit_binary_logit(df, target, features, positive)
  c(model, list(type = "logistic"))
}

#' Generate positive-class scores for a fitted model
#' @param model Fitted model object
#' @param newdata Data to score
#' @export
predict_risk_scores <- function(model, newdata) {
  if (!is.null(model$bins)) {
    absent <- setdiff(model$features, names(newdata))
    if (length(absent)) {
      stop(sprintf("Column(s) not found: %s", paste(absent, collapse = ", ")), call. = FALSE)
    }
    encoded <- .woe_transform(newdata, model$bins)
    return(as.numeric(stats::predict(model$model,
                                     newdata = encoded[, model$features, drop = FALSE],
                                     type = "response")))
  }

  preds <- stats::predict(model$model, newdata, type = "prob")
  if (!is.data.frame(preds)) return(as.numeric(preds))
  wanted <- paste0(".pred_", model$positive)
  prob_cols <- grep("^\\.pred", names(preds), value = TRUE)
  if (wanted %in% names(preds)) {
    as.numeric(preds[[wanted]])
  } else if (length(prob_cols)) {
    as.numeric(preds[[prob_cols[length(prob_cols)]]])
  } else {
    as.numeric(preds[[1L]])
  }
}
