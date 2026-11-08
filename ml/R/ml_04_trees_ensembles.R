# ml_04_trees_ensembles.R -- Trees, random forests and gradient boosting (ISLR ch. 8; ESL sec. 9.2,
# ch. 10 and 15).
#
# - A single regression/classification tree (rpart), pruned by cross-validation (cost-complexity).
# - Random forests (ranger, 500 trees; mtry from a small grid on the household folds).
# - Gradient boosting (xgboost): shallow trees, learning rate 0.03, row and column subsampling,
#   the number of rounds chosen by early stopping on the household folds. The loss matches the
#   outcome: squared error for log spending, logistic for the binary outcomes, Poisson for visit
#   counts, and Tweedie (a point mass at zero plus a continuous tail) for spending itself, the
#   loss insurers use for claims (Yang, Qian and Zou 2018).
# Output: output/ml/results_R.csv (chapter "04 trees and ensembles"); the fitted xgboost models
# are saved to output/ml/xgb_*.json for chapter 9 (interpretation).
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages({library(rpart); library(ranger); library(xgboost)})
ch <- "04 trees and ensembles"
set.seed(1)   # rpart's cross-validation folds are random
f_all <- reformulate(predictors_log)
res <- list()

# ---- a single tree, pruned by 5-fold CV ---------------------------------------------------------------
for (y in c("log_cost", "cost", "high_cost", "any_er", "any_ip", "ob_visits")) {
  meth <- if (y %in% c("high_cost", "any_er", "any_ip")) "class" else if (y == "ob_visits") "poisson" else "anova"
  t0 <- rpart(update(f_all, as.formula(paste(y, "~ ."))), data = train, method = meth,
              control = rpart.control(cp = 0.001, xval = 5, minbucket = 20))
  cp <- t0$cptable[which.min(t0$cptable[, "xerror"]), "CP"]
  t1 <- prune(t0, cp = cp)
  p <- if (meth == "class") predict(t1, test, type = "prob")[, "1"] else predict(t1, test)
  res[[length(res) + 1]] <- evaluate(y, p, "Tree (pruned by CV)", ch)
  if (y == "high_cost") cat("Pruned tree for the top-10% outcome has", sum(t1$frame$var == "<leaf>"), "leaves\n")
}

# ---- random forests ------------------------------------------------------------------------------------
rf_cv <- function(y, classif) {
  grid <- c(4, 8, 16)
  d <- train; if (classif) d[[y]] <- factor(d[[y]])
  err <- sapply(grid, function(m) mean(sapply(1:5, function(f) {
    tr <- train$fold != f
    r <- ranger(update(f_all, as.formula(paste(y, "~ ."))), data = d[tr, ], num.trees = 300, mtry = m,
                probability = classif, min.node.size = if (classif) 10 else 5, seed = 1, num.threads = 2)
    p <- predict(r, train[!tr, ])$predictions; if (classif) p <- p[, "1"]
    mean((train[[y]][!tr] - p)^2)
  })))
  grid[which.min(err)]
}
for (y in c("log_cost", "cost", "high_cost", "any_er", "any_ip", "ob_visits")) {
  classif <- y %in% c("high_cost", "any_er", "any_ip")
  d <- train; if (classif) d[[y]] <- factor(d[[y]])
  m <- rf_cv(y, classif)
  r <- ranger(update(f_all, as.formula(paste(y, "~ ."))), data = d, num.trees = 500, mtry = m,
              probability = classif, min.node.size = if (classif) 10 else 5, seed = 1, num.threads = 2,
              importance = "permutation")
  p <- predict(r, test)$predictions; if (classif) p <- p[, "1"]
  res[[length(res) + 1]] <- evaluate(y, p, "Random forest", ch)
  cat(y, ": mtry =", m, "\n")
}

# ---- gradient boosting (xgboost) ------------------------------------------------------------------------
Xtr <- x_matrix(train); Xte <- x_matrix(test)
folds <- lapply(1:5, function(f) which(train$fold == f))
obj <- c(log_cost = "reg:squarederror", cost = "reg:tweedie", high_cost = "binary:logistic",
         any_er = "binary:logistic", any_ip = "binary:logistic", ob_visits = "count:poisson")
for (y in names(obj)) {
  dtr <- xgb.DMatrix(Xtr, label = train[[y]])
  par <- xgb.params(objective = obj[[y]], learning_rate = 0.03, max_depth = 3, subsample = 0.8,
                    colsample_bytree = 0.8, min_child_weight = 5, nthread = 2, seed = 1)
  if (y == "cost") par$tweedie_variance_power <- 1.5
  cv <- xgb.cv(par, dtr, nrounds = 3000, folds = folds, early_stopping_rounds = 100, verbose = FALSE)
  n <- cv$early_stop$best_iteration
  b <- xgb.train(par, dtr, nrounds = n, verbose = 0)
  res[[length(res) + 1]] <- evaluate(y, predict(b, Xte), paste0("Boosting (xgboost, ", sub(".*:", "", obj[[y]]), ")"), ch)
  xgb.save(b, file.path(out_dir, paste0("xgb_", y, ".json")))
  cat(y, ": boosting rounds =", n, "\n")
}
# Boosting the spending itself with a squared-error loss, for comparison with the Tweedie loss
dtr <- xgb.DMatrix(Xtr, label = train$cost)
par <- xgb.params(objective = "reg:squarederror", learning_rate = 0.03, max_depth = 3, subsample = 0.8,
                  colsample_bytree = 0.8, min_child_weight = 5, nthread = 2, seed = 1)
cv <- xgb.cv(par, dtr, nrounds = 3000, folds = folds, early_stopping_rounds = 100, verbose = FALSE)
b <- xgb.train(par, dtr, nrounds = cv$early_stop$best_iteration, verbose = 0)
res[[length(res) + 1]] <- evaluate("cost", predict(b, Xte), "Boosting (xgboost, squarederror)", ch)

res <- do.call(rbind, res); log_results(res); show(res)
