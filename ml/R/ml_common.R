# ml_common.R -- Shared pieces for the machine learning walkthrough (R): the data, the
# predictor sets, design matrices, survey-weighted metrics, and a results log.
# Every script in ml/R/ starts with source("ml/R/ml_common.R").
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

ml_file <- "data/meps_ml.csv"
out_dir <- "output/ml"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
if (!file.exists(ml_file)) stop("Run ml/R/ml_00_extract.R (or ml/python/ml_00_extract.py) first.")

ml <- read.csv(ml_file, stringsAsFactors = FALSE)
cat_vars <- c("race_eth", "region", "marital", "education", "poverty", "insurance")
for (v in cat_vars) ml[[v]] <- factor(ml[[v]])
ml$region <- relevel(ml$region, "South"); ml$race_eth <- relevel(ml$race_eth, "White")
ml$insurance <- relevel(ml$insurance, "Any private"); ml$marital <- relevel(ml$marital, "Married")
ml$education <- relevel(ml$education, "High school"); ml$poverty <- relevel(ml$poverty, "High income")

id_vars  <- c("person", "household", "weight", "stratum", "psu", "test", "fold")
outcomes <- c("cost", "high_cost", "log_cost", "ob_visits", "any_er", "any_ip")
predictors <- setdiff(names(ml), c(id_vars, outcomes))
num_vars <- setdiff(predictors, cat_vars)
# Spending and visit counts are very skewed; most models do better with them on a log scale.
skewed <- c("cost_2022", "oop_2022", "ob_visits_2022", "er_visits_2022", "stays_2022", "rx_2022")
for (v in skewed) ml[[paste0("log_", v)]] <- log1p(ml[[v]])
predictors_log <- c(setdiff(predictors, skewed), paste0("log_", skewed))

train <- ml[ml$test == 0, ]
test  <- ml[ml$test == 1, ]

# Design matrix with dummy variables (for glmnet, xgboost, SVMs, neural nets, ...)
x_matrix <- function(d, vars = predictors_log) {
  m <- model.matrix(~ . - 1, data = d[, vars], contrasts.arg = lapply(d[, intersect(vars, cat_vars), drop = FALSE],
                                                                       contrasts, contrasts = FALSE))
  m
}
# Standardize with the training means and SDs (needed for penalties, distances and SVMs)
scaler <- function(xtr) { mu <- colMeans(xtr); s <- apply(xtr, 2, sd); s[s == 0] <- 1
  function(x) sweep(sweep(x, 2, mu, "-"), 2, s, "/") }

# ---- survey-weighted metrics on the test set --------------------------------------------------------
wmean <- function(x, w) sum(w * x) / sum(w)
w_rmse <- function(y, p, w) sqrt(wmean((y - p)^2, w))
w_mae  <- function(y, p, w) wmean(abs(y - p), w)
w_r2   <- function(y, p, w) 1 - wmean((y - p)^2, w) / wmean((y - wmean(y, w))^2, w)
w_auc  <- function(y, p, w) {                      # P(score of a random positive > a random negative), weighted
  o <- order(p); y <- y[o]; p <- p[o]; w <- w[o]
  wn <- ifelse(y == 0, w, 0); wp <- ifelse(y == 1, w, 0)
  g <- split(seq_along(p), p)                      # ties share half the credit
  cum_neg <- 0; s <- 0
  for (i in g) { s <- s + sum(wp[i]) * (cum_neg + sum(wn[i]) / 2); cum_neg <- cum_neg + sum(wn[i]) }
  s / (sum(wp) * sum(wn))
}
w_brier <- function(y, p, w) wmean((y - p)^2, w)
w_logloss <- function(y, p, w) { p <- pmin(pmax(p, 1e-12), 1 - 1e-12); -wmean(y * log(p) + (1 - y) * log(1 - p), w) }
w_poisdev <- function(y, p, w) { p <- pmax(p, 1e-12); 2 * wmean(ifelse(y > 0, y * log(y / p), 0) - (y - p), w) }

# Evaluate predictions for one outcome on the test set; returns a one-row data frame
evaluate <- function(outcome, pred, model, chapter, d = test) {
  y <- d[[outcome]]; w <- d$weight
  if (outcome %in% c("cost", "log_cost")) {
    data.frame(chapter, model, outcome, metric = c("RMSE", "MAE", "R2"),
               value = c(w_rmse(y, pred, w), w_mae(y, pred, w), w_r2(y, pred, w)))
  } else if (outcome == "ob_visits") {
    data.frame(chapter, model, outcome, metric = c("Poisson deviance", "RMSE", "R2"),
               value = c(w_poisdev(y, pred, w), w_rmse(y, pred, w), w_r2(y, pred, w)))
  } else {
    data.frame(chapter, model, outcome, metric = c("AUC", "Brier", "Log loss"),
               value = c(w_auc(y, pred, w), w_brier(y, pred, w), w_logloss(y, pred, w)))
  }
}
# Append results to output/ml/results_R.csv (one file across chapters; reruns replace their rows)
log_results <- function(res) {
  f <- file.path(out_dir, "results_R.csv")
  old <- if (file.exists(f)) read.csv(f) else NULL
  if (!is.null(old)) old <- old[!(paste(old$chapter, old$model, old$outcome) %in% paste(res$chapter, res$model, res$outcome)), ]
  all <- rbind(old, res)
  write.csv(all, f, row.names = FALSE)
  invisible(all)
}
show <- function(res) {
  for (y in unique(res$outcome)) {
    r <- res[res$outcome == y, ]
    w <- reshape(r[, c("model", "metric", "value")], idvar = "model", timevar = "metric", direction = "wide")
    names(w) <- sub("^value\\.", "", names(w))
    cat("\n", y, "\n", sep = ""); print(w, digits = 4, row.names = FALSE)
  }
}
