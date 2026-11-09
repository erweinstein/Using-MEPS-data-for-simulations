# ml_14_updated_super_learner.R -- R version of ml/python/ml_14_updated_super_learner.py, with the
# SuperLearner package (Polley, LeDell, Kennedy and van der Laan): an updated library, several
# meta-learners, and a discrete Super Learner over learners and ensembles chosen by a second level of
# cross-validation on the household folds. See the Python script's header for the ideas and sources.
#
# Differences from the Python version:
#   - no TabPFN or TabM (Python packages; chapter 11 shows how to call them through reticulate);
#   - no input-dependent weights (SuperLearner's meta-learners see only the predictions, not X);
#   - test predictions come from learners refitted on all the training data (SuperLearner's way),
#     not fold-bagged;
#   - the baseline is the same kind of stack as chapter 13's, rebuilt inside SuperLearner (NNLS on
#     chapter 13's kinds of learners), since chapter 13's R script does not save its test predictions.
# The learners: GLM, lasso, ridge and elastic net (glmnet), MARS (earth), a GAM (gam), CART (rpart),
# random forest and extremely randomized trees (ranger), two XGBoost and one LightGBM configuration,
# an SVM (e1071) and a neural network (nnet). Greedy ensemble selection (Caruana et al. 2004) is
# written below as a SuperLearner "method", which is how to add any meta-learner of your own.
#
# Needs data/meps_ml.csv, data/meps_stays.csv and data/meps_util_2023.csv (chapters 0 and 13).
# Usage:  Rscript ml/R/ml_14_updated_super_learner.R [S3 S3b S1 S2 S4]
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

suppressMessages({library(SuperLearner); library(ggplot2)})
out <- file.path("output", "ml", "ch14"); docs <- file.path("docs", "ml")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
BLUE <- "#2a78d6"; ORANGE <- "#eb6834"; AQUA <- "#1baf7a"; INK <- "#2b2b29"
theme_set(theme_minimal(base_size = 9) + theme(panel.grid.minor = element_blank(), plot.title.position = "plot"))
set.seed(14)

ml_drop <- c("person", "household", "weight", "stratum", "psu", "test", "fold", "cost", "high_cost", "log_cost",
             "ob_visits", "any_er", "any_ip")
skewed <- c("cost_2022", "oop_2022", "ob_visits_2022", "er_visits_2022", "stays_2022", "rx_2022")
st_drop <- c("stay", "household", "person", "weight", "stratum", "psu", "test", "fold", "file_year", "nights", "log_nights", "long_stay")
SCEN <- list(
  S1 = list(file = "data/meps_ml.csv", y = "log_cost", kind = "reg", drop = ml_drop, log = skewed, title = "Log(1 + 2023 spending)"),
  S2 = list(file = "data/meps_ml.csv", y = "high_cost", kind = "clf", drop = ml_drop, log = skewed, title = "Top 10% of 2023 spenders"),
  S3 = list(file = "data/meps_stays.csv", y = "log_nights", kind = "reg", drop = st_drop, log = character(0), title = "Nights per hospital stay (log)"),
  S3b = list(file = "data/meps_stays.csv", y = "long_stay", kind = "clf", drop = st_drop, log = character(0), title = "Stay of a week or more"),
  S4 = list(file = "data/meps_util_2023.csv", y = "high_use", kind = "clf", log = character(0), title = "High use of care in 2023",
            drop = c("person", "household", "weight", "stratum", "psu", "test", "fold", "utilization", "high_use", "white_nh")))

wmean <- function(x, w) sum(w * x) / sum(w)
w_r2 <- function(y, p, w) 1 - wmean((y - p)^2, w) / wmean((y - wmean(y, w))^2, w)
w_auc <- function(y, p, w) { d <- aggregate(cbind(pos = w * (y == 1), neg = w * (y == 0)) ~ p, data.frame(p, y, w), sum)
  cn <- cumsum(d$neg) - d$neg; sum(d$pos * (cn + d$neg / 2)) / (sum(d$pos) * sum(d$neg)) }
clip <- function(p) pmin(pmax(p, 1e-4), 1 - 1e-4)
logloss <- function(y, p) -mean(y * log(clip(p)) + (1 - y) * log(1 - clip(p)))
hh_boot <- function(y, P, w, hh, fun, B = 300) { u <- unique(hh); idx <- match(hh, u)
  t(replicate(B, { cnt <- tabulate(sample.int(length(u), replace = TRUE), length(u))[idx]; k <- cnt > 0
    apply(P[k, , drop = FALSE], 2, function(p) fun(y[k], p, (w * cnt)[k])) })) }
encode <- function(tr, d, cols) {             # one 0/1 column per level (levels from the training data)
  out <- lapply(cols, function(c) if (is.numeric(tr[[c]])) setNames(data.frame(as.numeric(d[[c]])), c) else {
    lv <- sort(unique(tr[[c]])); m <- sapply(lv, function(l) as.numeric(d[[c]] == l)); colnames(m) <- paste0(c, "=", lv); as.data.frame(m) })
  X <- do.call(cbind, out); names(X) <- make.names(names(X), unique = TRUE); X
}

# ---- learners: SuperLearner's wrappers, variants made with create.Learner, and three written here ---------------
SL.xgb <- function(Y, X, newX, family, obsWeights, depth = 2, rounds = 500, eta = 0.03, mcw = 5, sub = 0.8, col = 0.8, ...) {
  m <- xgboost::xgb.train(params = list(objective = if (family$family == "binomial") "binary:logistic" else "reg:squarederror",
                                        eta = eta, max_depth = depth, subsample = sub, colsample_bytree = col, min_child_weight = mcw, nthread = 2),
                          data = xgboost::xgb.DMatrix(as.matrix(X), label = Y, weight = obsWeights), nrounds = rounds, verbose = 0)
  fit <- list(object = m); class(fit) <- "SL.xgb"
  list(pred = predict(m, xgboost::xgb.DMatrix(as.matrix(newX))), fit = fit)
}
predict.SL.xgb <- function(object, newdata, ...) predict(object$object, xgboost::xgb.DMatrix(as.matrix(newdata)))
SL.xgb.deep <- function(...) SL.xgb(..., depth = 6, rounds = 600, eta = 0.02, mcw = 10, sub = 0.7, col = 0.6)
SL.lgbm <- function(Y, X, newX, family, obsWeights, ...) {
  bin <- family$family == "binomial"
  m <- lightgbm::lgb.train(params = list(objective = if (bin) "binary" else "regression", learning_rate = 0.03, num_leaves = 15,
                                         min_data_in_leaf = 20, bagging_fraction = 0.8, bagging_freq = 1, feature_fraction = 0.8,
                                         lambda_l2 = 1, num_threads = 2, verbose = -1, seed = 1),
                           data = lightgbm::lgb.Dataset(as.matrix(X), label = Y, weight = obsWeights), nrounds = 400)
  fit <- list(object = m); class(fit) <- "SL.lgbm"
  list(pred = predict(m, as.matrix(newX)), fit = fit)
}
predict.SL.lgbm <- function(object, newdata, ...) predict(object$object, as.matrix(newdata))
SL.nnet3 <- function(Y, X, newX, family, obsWeights, ...) {      # one hidden layer, 3 units, decay 5, three starts averaged
  mu <- colMeans(X); s <- apply(X, 2, sd); s[s == 0] <- 1; sc <- function(Z) sweep(sweep(as.matrix(Z), 2, mu, "-"), 2, s, "/")
  set.seed(1); bin <- family$family == "binomial"
  ms <- lapply(1:3, function(r) nnet::nnet(sc(X), Y, size = 3, decay = 5, maxit = 500, linout = !bin, entropy = bin, trace = FALSE))
  fit <- list(ms = ms, sc = sc); class(fit) <- "SL.nnet3"
  list(pred = predict(fit, newX), fit = fit)
}
predict.SL.nnet3 <- function(object, newdata, ...) rowMeans(sapply(object$ms, function(m) as.numeric(predict(m, object$sc(newdata)))))
lasso <- create.Learner("SL.glmnet", params = list(alpha = 1), name_prefix = "SL.lasso")
ridge <- create.Learner("SL.glmnet", params = list(alpha = 0), name_prefix = "SL.ridge")
enet <- create.Learner("SL.glmnet", params = list(alpha = 0.5), name_prefix = "SL.enet")
rf <- create.Learner("SL.ranger", params = list(num.trees = 500, min.node.size = 5, num.threads = 2), name_prefix = "SL.rf")
et <- create.Learner("SL.ranger", params = list(num.trees = 500, min.node.size = 5, splitrule = "extratrees", num.threads = 2), name_prefix = "SL.extratrees")
svmC <- create.Learner("SL.svm", params = list(type.class = "C-classification"), name_prefix = "SL.svmC")   # SL.svm's default nu = 0.5 is infeasible for a 10-20% outcome
tree <- create.Learner("SL.rpart", params = list(maxdepth = 5, minbucket = 20, cp = 0), name_prefix = "SL.cart")
LIB <- c("SL.glm", lasso$names, ridge$names, enet$names, "SL.earth", "SL.gam", tree$names, rf$names, et$names,
         "SL.xgb", "SL.xgb.deep", "SL.lgbm", svmC$names, "SL.nnet3")
CH13_LIKE <- c("SL.glm", lasso$names, ridge$names, enet$names, tree$names, rf$names, "SL.xgb", svmC$names, "SL.nnet3")

# ---- greedy ensemble selection as a SuperLearner method ----------------------------------------------------------
method.caruana <- function() list(
  require = NULL,
  computeCoef = function(Z, Y, libraryNames, verbose, obsWeights, control, ...) {
    loss <- if (all(Y %in% 0:1)) function(p) logloss(Y, p) else function(p) mean((Y - p)^2)
    cnt <- numeric(ncol(Z)); s <- numeric(nrow(Z))
    for (t in 1:100) { j <- which.min(apply(Z, 2, function(z) loss((s + z) / t))); cnt[j] <- cnt[j] + 1; s <- s + Z[, j] }
    coef <- cnt / sum(cnt); names(coef) <- libraryNames
    list(cvRisk = apply(Z, 2, function(z) loss(z)), coef = coef, optimizer = NULL)
  },
  computePred = function(predY, coef, control, ...) as.numeric(predY %*% coef))

run <- function(sid) {
  S <- SCEN[[sid]]; clf <- S$kind == "clf"; t0 <- Sys.time()
  d <- read.csv(S$file, stringsAsFactors = FALSE, colClasses = c(person = "character"))
  for (v in S$log) d[[v]] <- log1p(d[[v]])
  cols <- setdiff(names(d), S$drop); tr <- d[d$test == 0, ]; te <- d[d$test == 1, ]
  Xtr <- encode(tr, tr, cols); Xte <- encode(tr, te, cols)
  keep <- sapply(Xtr, sd) > 0; Xtr <- Xtr[keep]; Xte <- Xte[keep]
  ytr <- tr[[S$y]]; yte <- te[[S$y]]; folds <- tr$fold
  fam <- if (clf) binomial() else gaussian()
  cat(sprintf("\n=== %s: %s -- %d training, %d test ===\n", sid, S$title, nrow(tr), nrow(te)))
  fit <- SuperLearner(ytr, Xtr, newX = Xte, family = fam, SL.library = LIB, method = "method.NNLS",
                      cvControl = list(V = 5, validRows = split(seq_len(nrow(tr)), folds)))
  print(round(cbind(cvRisk = fit$cvRisk, coef = fit$coef), 4))
  Z <- fit$Z; colnames(Z) <- LIB; Zt <- fit$library.predict; colnames(Zt) <- LIB
  if (clf) { Z <- clip(Z); Zt <- clip(Zt) }
  lossf <- if (clf) function(y, p) logloss(y, p) else function(y, p) mean((y - p)^2)
  metas <- c(list(`NNLS, ch13-like library` = list(m = method.NNLS(), lib = CH13_LIKE), `NNLS, full library` = list(m = method.NNLS(), lib = LIB)),
             if (clf) list(`Logit convex (CC_nloglik), full library` = list(m = method.CC_nloglik(), lib = LIB)),
             list(`Ensemble selection (Caruana), full library` = list(m = method.caruana(), lib = LIB)))
  meta_fit <- function(M, rows) { cf <- M$m$computeCoef(Z = Z[rows, M$lib, drop = FALSE], Y = ytr[rows], libraryNames = M$lib, verbose = FALSE,
                                                        obsWeights = rep(1, sum(rows)), control = list(trimLogit = 1e-4))$coef
    cf[is.na(cf)] <- 0; setNames(as.numeric(cf), M$lib) }
  meta_pred <- function(M, cf, P) as.numeric(M$m$computePred(predY = P[, M$lib, drop = FALSE], coef = cf, control = list(trimLogit = 1e-4)))
  cvr <- sapply(LIB, function(l) lossf(ytr, Z[, l]))
  for (k in names(metas)) {                          # level-2 cross-validation on the household folds
    p <- numeric(nrow(tr))
    for (f in 1:5) { cf <- meta_fit(metas[[k]], folds != f); p[folds == f] <- meta_pred(metas[[k]], cf, Z[folds == f, , drop = FALSE]) }
    cvr[k] <- lossf(ytr, p)
  }
  chosen <- names(which.min(cvr))
  pred <- lapply(LIB, function(l) Zt[, l]); names(pred) <- LIB
  wts <- list()
  for (k in names(metas)) { cf <- meta_fit(metas[[k]], rep(TRUE, nrow(tr))); wts[[k]] <- cf; pred[[k]] <- meta_pred(metas[[k]], cf, Zt) }
  pred[["Updated Super Learner"]] <- pred[[chosen]]
  mfun <- if (clf) w_auc else w_r2; P <- do.call(cbind, pred); w <- te$weight
  boot <- hh_boot(yte, P, w, te$household, mfun)
  j0 <- which(names(pred) == "NNLS, ch13-like library"); jb <- which(names(pred) == "SL.glm")
  res <- data.frame(scenario = sid, candidate = names(pred), cv_risk = c(cvr[names(pred)[-length(pred)]], cvr[chosen]),
                    test = apply(P, 2, function(p) mfun(yte, p, w)), lo = apply(boot, 2, quantile, 0.025), hi = apply(boot, 2, quantile, 0.975),
                    diff_vs_ch13_like = apply(P, 2, function(p) mfun(yte, p, w)) - mfun(yte, P[, j0], w),
                    d13_lo = apply(boot - boot[, j0], 2, quantile, 0.025), d13_hi = apply(boot - boot[, j0], 2, quantile, 0.975),
                    diff_vs_glm = apply(P, 2, function(p) mfun(yte, p, w)) - mfun(yte, P[, jb], w),
                    chosen = names(pred) == chosen, row.names = NULL)
  names(res)[names(res) == "test"] <- if (clf) "test_AUC" else "test_R2"
  write.csv(res, file.path(out, paste0(sid, "_results_R.csv")), row.names = FALSE)
  W <- do.call(cbind, lapply(wts, function(cf) { v <- setNames(numeric(length(LIB)), LIB); v[names(cf)] <- cf; v }))
  write.csv(W, file.path(out, paste0(sid, "_weights_R.csv")))
  print(res[, c(2, 3, 4, 5, 6, 7, 8, 9)], digits = 3, row.names = FALSE)
  cat("  chosen by cross-validated risk:", chosen, "\n"); print(round(W[rowSums(W) > 0.005, , drop = FALSE], 3))
  r <- res; r$candidate <- factor(r$candidate, rev(r$candidate))
  r$type <- ifelse(r$candidate == "Updated Super Learner", "Updated Super Learner", ifelse(r$candidate == "NNLS, ch13-like library", "Chapter 13-like stack", "Other"))
  p <- ggplot(r, aes(y = candidate, colour = type)) + geom_errorbar(aes(xmin = lo, xmax = hi), width = 0, orientation = "y", linewidth = 0.8) +
    geom_point(aes(x = .data[[names(res)[4]]]), size = 2) + scale_colour_manual(NULL, values = c(`Updated Super Learner` = ORANGE, `Chapter 13-like stack` = AQUA, Other = BLUE)) +
    labs(x = paste("Test-data", if (clf) "AUC" else "R2", "(survey-weighted; household-bootstrap 95% interval)"), y = NULL,
         title = paste0(S$title, ": the updated Super Learner (chosen: ", chosen, ")")) + theme(legend.position = "bottom")
  ggsave(file.path(out, sprintf("fig14_%s_candidates_R.png", sid)), p, width = 7.4, height = 6, dpi = 200, bg = "white")
  file.copy(file.path(out, sprintf("fig14_%s_candidates_R.png", sid)), file.path(docs, sprintf("fig14_%s_candidates_R.png", sid)), overwrite = TRUE)
  cat(sprintf("  %s done in %.1f min\n", sid, as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  res
}

args <- commandArgs(trailingOnly = TRUE); todo <- if (length(args)) args else c("S3", "S3b", "S1", "S2", "S4")
invisible(lapply(todo, run))
fs <- list.files(out, "^S[0-9b]+_results_R\\.csv$", full.names = TRUE)
write.csv(dplyr::bind_rows(lapply(fs, read.csv)), file.path(out, "all_results_R.csv"), row.names = FALSE)
