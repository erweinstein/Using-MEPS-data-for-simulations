# ml_08_stacking.R -- Stacked generalization and the Super Learner (Wolpert 1992; Breiman 1996;
# van der Laan, Polley and Hubbard 2007; ESL sec. 8.8 and ch. 16), and how sure we can be that one
# model beats another on a test set of 1,879 people.
#
# The Super Learner fits each candidate ("base learner") on 4 of the 5 household folds and
# predicts the fifth, so every training person gets an out-of-fold prediction from every learner.
# A meta-learner then finds the combination of learners that predicts best out of fold (here a
# non-negative weighted average, the SuperLearner default), and the learners are refitted on all
# the training data. The "discrete" Super Learner simply picks the learner with the lowest
# cross-validated risk. Theory: the Super Learner does asymptotically as well as the best
# combination of its learners (the oracle inequality).
#
# Learners: the mean; a GLM (linear, logistic, or quasi-Poisson for spending); the lasso; a
# random forest; boosting (xgboost, with chapter 4's settings and a fixed number of rounds).
# Outcomes: log_cost, cost and high_cost.
# The last part bootstraps the test households (2,000 resamples) to put intervals on the test
# metrics and on the difference between the Super Learner and the best single learner.
# Output: output/ml/results_R.csv (chapter "08 stacking"), output/ml/sl_weights_R.csv,
# output/ml/test_bootstrap_R.csv.
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages({library(SuperLearner); library(glmnet); library(ranger); library(xgboost)})
ch <- "08 stacking"
set.seed(1)
Xtr <- as.data.frame(x_matrix(train)); Xte <- as.data.frame(x_matrix(test))
names(Xtr) <- names(Xte) <- make.names(names(Xtr))
valid <- lapply(1:5, function(f) which(train$fold == f))

# ---- learners written for this chapter (SuperLearner's own wrappers predate xgboost 3) -------------
SL.qpois <- function(Y, X, newX, family, obsWeights, ...) {          # GLM with log link, Poisson variance
  m <- glm(Y ~ ., data = X, family = quasipoisson(link = "log"), control = glm.control(maxit = 100))
  list(pred = predict(m, newX, type = "response"), fit = structure(list(object = m), class = "SL.qpois"))
}
predict.SL.qpois <- function(object, newdata, ...) predict(object$object, newdata, type = "response")
SL.lasso <- function(Y, X, newX, family, obsWeights, ...) {
  fam <- if (family$family == "binomial") "binomial" else "gaussian"
  m <- cv.glmnet(as.matrix(X), Y, family = fam, alpha = 1, nfolds = 5)
  list(pred = as.numeric(predict(m, as.matrix(newX), s = "lambda.min", type = "response")),
       fit = structure(list(object = m), class = "SL.lasso"))
}
predict.SL.lasso <- function(object, newdata, ...) as.numeric(predict(object$object, as.matrix(newdata), s = "lambda.min", type = "response"))
SL.rf <- function(Y, X, newX, family, obsWeights, ...) {
  bin <- family$family == "binomial"
  m <- ranger(x = X, y = if (bin) factor(Y) else Y, num.trees = 500, mtry = 8, probability = bin,
              min.node.size = if (bin) 10 else 5, num.threads = 2, seed = 1)
  p <- predict(m, newX)$predictions; if (bin) p <- p[, "1"]
  list(pred = p, fit = structure(list(object = m, bin = bin), class = "SL.rf"))
}
predict.SL.rf <- function(object, newdata, ...) { p <- predict(object$object, newdata)$predictions; if (object$bin) p[, "1"] else p }
make_xgb <- function(objective, rounds, power = NULL) {
  function(Y, X, newX, family, obsWeights, ...) {
    par <- xgb.params(objective = objective, learning_rate = 0.03, max_depth = 3, subsample = 0.8,
                      colsample_bytree = 0.8, min_child_weight = 5, nthread = 2, seed = 1)
    if (!is.null(power)) par$tweedie_variance_power <- power
    m <- xgb.train(par, xgb.DMatrix(as.matrix(X), label = Y), nrounds = rounds, verbose = 0)
    list(pred = predict(m, as.matrix(newX)), fit = structure(list(object = m), class = "SL.xgbc"))
  }
}
predict.SL.xgbc <- function(object, newdata, ...) predict(object$object, as.matrix(newdata))
SL.xgb_sq <- make_xgb("reg:squarederror", 300)          # rounds near chapter 4's early-stopping choices
SL.xgb_tw <- make_xgb("reg:tweedie", 200, 1.5)
SL.xgb_lg <- make_xgb("binary:logistic", 170)

libs <- list(log_cost = c("SL.mean", "SL.glm", "SL.lasso", "SL.rf", "SL.xgb_sq"),
             cost = c("SL.mean", "SL.glm", "SL.qpois", "SL.lasso", "SL.rf", "SL.xgb_tw"),
             high_cost = c("SL.mean", "SL.glm", "SL.lasso", "SL.rf", "SL.xgb_lg"))
res <- list(); wts <- list(); preds <- list()
for (y in names(libs)) {
  fam <- if (y == "high_cost") binomial() else gaussian()
  meth <- if (y == "high_cost") "method.NNloglik" else "method.NNLS"
  sl <- SuperLearner(train[[y]], Xtr, newX = Xte, family = fam, SL.library = libs[[y]], method = meth,
                     cvControl = list(V = 5, validRows = valid))
  wts[[y]] <- data.frame(outcome = y, learner = names(sl$coef), weight = round(sl$coef, 3), cv_risk = sl$cvRisk)
  print(wts[[y]], row.names = FALSE)
  disc <- which.min(sl$cvRisk)
  preds[[y]] <- cbind(SL = as.numeric(sl$SL.predict), sl$library.predict)
  res[[length(res) + 1]] <- evaluate(y, as.numeric(sl$SL.predict), "Super Learner", ch)
  res[[length(res) + 1]] <- evaluate(y, sl$library.predict[, disc], paste0("Discrete Super Learner (", names(disc), ")"), ch)
  for (j in colnames(sl$library.predict)) res[[length(res) + 1]] <- evaluate(y, sl$library.predict[, j], paste0("  learner: ", sub("_All$", "", j)), ch)
}
res <- do.call(rbind, res); log_results(res); show(res)
write.csv(do.call(rbind, wts), file.path(out_dir, "sl_weights_R.csv"), row.names = FALSE)

# ---- how much does the test set tell us? A household bootstrap of the test metrics ----------------
metric <- function(y, p, w) if (y == "high_cost") w_auc(test$high_cost[idx_], p, w) else w_r2(test[[y]][idx_], p, w)
hh <- unique(test$household); rows_of <- split(seq_len(nrow(test)), test$household)
boot <- list()
for (y in names(preds)) {
  P <- preds[[y]]
  single <- setdiff(colnames(P), c("SL", "SL.mean_All"))
  best <- single[which.max(   # the best single learner on the test set (favours it, so the comparison is conservative)
    sapply(single, function(j) { idx_ <<- seq_len(nrow(test)); metric(y, P[, j], test$weight) }))]
  B <- 2000; out <- matrix(NA, B, 3)
  for (b in 1:B) {
    idx_ <<- unlist(rows_of[sample(length(hh), replace = TRUE)], use.names = FALSE)
    w <- test$weight[idx_]
    out[b, ] <- c(metric(y, P[idx_, "SL"], w), metric(y, P[idx_, best], w), 0)
    out[b, 3] <- out[b, 1] - out[b, 2]
  }
  idx_ <<- seq_len(nrow(test))
  est <- c(metric(y, P[, "SL"], test$weight), metric(y, P[, best], test$weight))
  boot[[y]] <- data.frame(outcome = y, metric = if (y == "high_cost") "AUC" else "R2", best_single = sub("_All$", "", best),
                          SL = est[1], SL_lo = quantile(out[, 1], 0.025), SL_hi = quantile(out[, 1], 0.975),
                          best = est[2], best_lo = quantile(out[, 2], 0.025), best_hi = quantile(out[, 2], 0.975),
                          diff = est[1] - est[2], diff_lo = quantile(out[, 3], 0.025), diff_hi = quantile(out[, 3], 0.975))
}
boot <- do.call(rbind, boot)
cat("\nTest-set metrics with 95% household-bootstrap intervals (2,000 resamples):\n"); print(boot, digits = 3, row.names = FALSE)
write.csv(boot, file.path(out_dir, "test_bootstrap_R.csv"), row.names = FALSE)
