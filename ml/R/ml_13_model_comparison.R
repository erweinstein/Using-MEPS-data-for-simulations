# ml_13_model_comparison.R -- R version of ml/python/ml_13_model_comparison.py: ten learners and a
# stacked ensemble on four MEPS problems, with in-sample and out-of-sample prediction plots, the
# variable importance of the best model, and (for yes/no outcomes) ROC curves and calibration.
#
# Same scenarios, splits, folds, learners and stacking rule as the Python script (see its header);
# the R learners are glmnet (lasso, ridge, elastic net), FNN (k nearest neighbors), rpart (CART),
# ranger (random forest), xgboost, e1071 (SVM, RBF kernel) and nnet (one hidden layer, averaged over
# three random starts as in chapter 6; R's nnet has no deeper networks, so this one is smaller than
# the Python version's two-layer perceptron).
# Stacking is non-negative least squares with weights summing to one (quadprog), as in pystacked.
#
# Needs data/meps_ml.csv (ml_00) and, for S3, S3b and S4, data/meps_stays.csv and
# data/meps_util_2023.csv (ml/python/ml_13a_stays_extract.py).
# Privacy: the predicted-vs-observed scatter grids show individuals and stay in output/ml/ch13/.
#
# Usage:  Rscript ml/R/ml_13_model_comparison.R [S1 S2 S3 S3b S4]
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

suppressMessages({library(ggplot2); library(patchwork)})
out <- file.path("output", "ml", "ch13"); docs <- file.path("docs", "ml")
dir.create(out, recursive = TRUE, showWarnings = FALSE); dir.create(docs, recursive = TRUE, showWarnings = FALSE)
set.seed(13)
BLUE <- "#2a78d6"; ORANGE <- "#eb6834"; AQUA <- "#1baf7a"; GRAY <- "#b4b2a9"; INK <- "#2b2b29"
theme_set(theme_minimal(base_size = 9) + theme(panel.grid.minor = element_blank(), plot.title.position = "plot",
                                               plot.title = element_text(colour = INK), strip.text = element_text(colour = INK)))

ml_drop <- c("person", "household", "weight", "stratum", "psu", "test", "fold", "cost", "high_cost", "log_cost",
             "ob_visits", "any_er", "any_ip")
skewed <- c("cost_2022", "oop_2022", "ob_visits_2022", "er_visits_2022", "stays_2022", "rx_2022")
st_drop <- c("stay", "household", "person", "weight", "stratum", "psu", "test", "fold", "file_year", "nights", "log_nights", "long_stay")
SCEN <- list(
  S1 = list(file = "data/meps_ml.csv", y = "log_cost", kind = "reg", drop = ml_drop, log = skewed,
            title = "Log(1 + 2023 spending), adults in Panel 27", unit = "log(1 + $)"),
  S2 = list(file = "data/meps_ml.csv", y = "high_cost", kind = "clf", drop = ml_drop, log = skewed,
            title = "Top 10% of 2023 spenders, adults in Panel 27"),
  S3 = list(file = "data/meps_stays.csv", y = "log_nights", kind = "reg", drop = st_drop, log = character(0),
            title = "Nights per hospital stay, adults 2021-2023 (log scale)", unit = "log(nights)"),
  S3b = list(file = "data/meps_stays.csv", y = "long_stay", kind = "clf", drop = st_drop, log = character(0),
             title = "Hospital stay of a week or more, adults 2021-2023"),
  S4 = list(file = "data/meps_util_2023.csv", y = "high_use", kind = "clf", log = character(0),
            drop = c("person", "household", "weight", "stratum", "psu", "test", "fold", "utilization", "high_use", "white_nh"),
            title = "High use of care in 2023 (10+ visits and nights; AI Fairness 360 definition)"))

# ---- metrics -------------------------------------------------------------------------------------------
wmean <- function(x, w) sum(w * x) / sum(w)
w_r2 <- function(y, p, w) 1 - wmean((y - p)^2, w) / wmean((y - wmean(y, w))^2, w)
w_brier <- function(y, p, w) wmean((y - p)^2, w)
w_auc <- function(y, p, w) {                       # weighted Mann-Whitney, ties count half
  d <- aggregate(cbind(pos = w * (y == 1), neg = w * (y == 0)) ~ p, data.frame(p, y, w), sum)
  cn <- cumsum(d$neg) - d$neg
  sum(d$pos * (cn + d$neg / 2)) / (sum(d$pos) * sum(d$neg))
}
w_roc <- function(y, p, w) { o <- order(-p); tp <- cumsum(w[o] * (y[o] == 1)); fp <- cumsum(w[o] * (y[o] == 0))
  data.frame(fpr = c(0, fp / max(fp)), tpr = c(0, tp / max(tp))) }
logloss <- function(y, p) { p <- pmin(pmax(p, 1e-6), 1 - 1e-6); -mean(y * log(p) + (1 - y) * log(1 - p)) }

# ---- encoding: one 0/1 column per level, levels fixed from the training data ---------------------------------
make_encoder <- function(tr, cols) {
  cats <- cols[!sapply(tr[cols], is.numeric)]
  lv <- lapply(tr[cats], function(x) sort(unique(x)))
  function(d) {
    m <- lapply(cols, function(c) if (c %in% cats) sapply(lv[[c]], function(l) as.numeric(d[[c]] == l)) else as.numeric(d[[c]]))
    nm <- unlist(lapply(cols, function(c) if (c %in% cats) paste0(c, "=", lv[[c]]) else c))
    X <- do.call(cbind, m); colnames(X) <- nm; X
  }
}
scaler <- function(X) { mu <- colMeans(X); s <- apply(X, 2, sd); s[s == 0] <- 1
  function(Z) sweep(sweep(Z, 2, mu, "-"), 2, s, "/") }

# ---- the ten learners: fit(X, y, par) returns a prediction function; grids tuned on the folds ----------------
lib_for <- function(kind) {
  clf <- kind == "clf"
  fam <- if (clf) "binomial" else "gaussian"
  glmnet_l <- function(alpha) list(grid = list(list(alpha = alpha)), fit = function(X, y, par, foldid = NULL) {
    if (is.null(foldid)) foldid <- sample(rep(1:5, length.out = nrow(X)))
    cv <- glmnet::cv.glmnet(X, y, family = fam, alpha = par$alpha, foldid = foldid, type.measure = if (clf) "deviance" else "mse")
    function(Z) as.numeric(predict(cv, Z, s = "lambda.min", type = "response"))
  }, glmnet = TRUE)
  list(
    OLS = list(grid = list(list()), fit = function(X, y, par) {
      keep <- !grepl("=", colnames(X)) | duplicated(sub("=.*", "", colnames(X)))   # drop the first level of each categorical variable
      keep <- keep & apply(X, 2, sd) > 0
      d <- data.frame(y = y, X[, keep, drop = FALSE], check.names = TRUE)
      m <- if (clf) suppressWarnings(glm(y ~ ., binomial, d)) else lm(y ~ ., d)
      function(Z) as.numeric(predict(m, data.frame(Z[, keep, drop = FALSE], check.names = TRUE), type = "response"))
    }),
    Lasso = glmnet_l(1), Ridge = glmnet_l(0),
    `Elastic net` = list(grid = lapply(c(0.2, 0.5, 0.8), function(a) list(alpha = a)), fit = glmnet_l(0)$fit, glmnet = TRUE),
    KNN = list(grid = lapply(if (clf) c(30, 60, 120, 240) else c(15, 30, 60, 120), function(k) list(k = k)),
               fit = function(X, y, par) { sc <- scaler(X); Xs <- sc(X)
                 function(Z) FNN::knn.reg(Xs, sc(Z), y, k = par$k)$pred }),
    `Tree (CART)` = list(grid = do.call(c, lapply(c(3, 5, 8), function(d) lapply(c(20, 60), function(l) list(depth = d, leaf = l)))),
                         fit = function(X, y, par) {
                           # "anova" on a 0/1 outcome (squared error = Gini) for both kinds: with rpart's "class" method a
                           # shallow tree for a 10-20% outcome never split here (its complexity check counts misclassifications)
                           m <- rpart::rpart(y ~ ., data.frame(y = y, X, check.names = FALSE), method = "anova",
                                             control = rpart::rpart.control(maxdepth = par$depth, minbucket = par$leaf, cp = 0, xval = 0))
                           function(Z) predict(m, data.frame(Z, check.names = FALSE)) }),
    `Random forest` = list(grid = do.call(c, lapply(c(0.2, 0.4), function(f) lapply(c(5, 20), function(l) list(frac = f, leaf = l)))),
                           fit = function(X, y, par) {
                             m <- ranger::ranger(x = X, y = if (clf) factor(y) else y, num.trees = 400, probability = clf,
                                                 mtry = max(1, floor(par$frac * ncol(X))), min.node.size = par$leaf, num.threads = 2, seed = 1)
                             function(Z) { p <- predict(m, Z)$predictions; if (clf) p[, "1"] else p } }),
    XGBoost = list(grid = do.call(c, lapply(c(200, 500), function(n) lapply(c(2, 4), function(d) list(n = n, depth = d)))),
                   fit = function(X, y, par, w = NULL) {
                     m <- xgboost::xgb.train(params = list(objective = if (clf) "binary:logistic" else "reg:squarederror",
                                                           eta = 0.03, max_depth = par$depth, subsample = 0.8, colsample_bytree = 0.8,
                                                           min_child_weight = 5, nthread = 2),
                                             data = xgboost::xgb.DMatrix(X, label = y, weight = w), nrounds = par$n, verbose = 0)
                     function(Z) predict(m, xgboost::xgb.DMatrix(Z)) }),
    SVM = list(grid = lapply(if (clf) c(0.5, 2) else c(0.3, 1, 3), function(C) list(C = C)), score = clf,
               fit = function(X, y, par) {
                 sc <- scaler(X); keep <- apply(X, 2, sd) > 0
                 m <- e1071::svm(sc(X)[, keep], if (clf) factor(y) else y, kernel = "radial", cost = par$C, scale = FALSE,
                                 type = if (clf) "C-classification" else "eps-regression", epsilon = 0.1, cachesize = 1000)
                 function(Z) { p <- predict(m, sc(Z)[, keep], decision.values = clf)
                   if (clf) { dv <- attr(p, "decision.values")[, 1]; if (colnames(attr(p, "decision.values"))[1] == "0/1") -dv else dv }
                   else as.numeric(p) } }),
    `Neural net` = list(grid = do.call(c, lapply(c(3, 8), function(sz) lapply(c(1, 10), function(a) list(size = sz, decay = a)))),
                        fit = function(X, y, par) {           # average of three random starts, as in chapter 6
      sc <- scaler(X); Xs <- sc(X); set.seed(1)
      ms <- lapply(1:3, function(r) nnet::nnet(Xs, y, size = par$size, decay = par$decay, maxit = 500, linout = !clf, entropy = clf,
                                               trace = FALSE, MaxNWts = 1e5))
      function(Z) { Zs <- sc(Z); rowMeans(sapply(ms, function(m) as.numeric(predict(m, Zs)))) } }))
}

nnls1 <- function(Z, y) {           # min ||y - Z a||^2, a >= 0, sum(a) = 1
  k <- ncol(Z); D <- crossprod(Z) + diag(1e-8, k)
  a <- quadprog::solve.QP(D, crossprod(Z, y), cbind(rep(1, k), diag(k)), c(1, rep(0, k)), meq = 1)$solution
  a[a < 1e-4] <- 0; a / sum(a)
}

hh_boot <- function(y, P, w, hh, fun, B = 300) {
  u <- unique(hh); idx <- match(hh, u)
  t(replicate(B, { cnt <- tabulate(sample.int(length(u), replace = TRUE), length(u))[idx]; k <- cnt > 0
    apply(P[k, , drop = FALSE], 2, function(p) fun(y[k], p, (w * cnt)[k])) }))
}

# ---- one scenario -----------------------------------------------------------------------------------------
run <- function(sid) {
  S <- SCEN[[sid]]; t0 <- Sys.time(); clf <- S$kind == "clf"
  d <- read.csv(S$file, stringsAsFactors = FALSE, colClasses = c(person = "character"))
  for (v in S$log) d[[v]] <- log1p(d[[v]])
  cols <- setdiff(names(d), S$drop)
  tr <- d[d$test == 0, ]; te <- d[d$test == 1, ]
  enc <- make_encoder(tr, cols); Xtr <- enc(tr); Xte <- enc(te)
  ytr <- tr[[S$y]]; yte <- te[[S$y]]; wtr <- tr$weight; wte <- te$weight; folds <- tr$fold
  lib <- lib_for(S$kind)
  nm <- function(k) if (k == "OLS" && clf) "Logistic" else k
  cat(sprintf("\n=== %s: %s -- %d training, %d test, %d columns ===\n", sid, S$title, nrow(tr), nrow(te), ncol(Xtr)))
  oof <- ins <- oos <- fits <- list(); info <- NULL
  for (k in names(lib)) {
    L <- lib[[k]]; t1 <- Sys.time()
    cvp <- lapply(L$grid, function(par) {          # out-of-fold predictions for each setting
      z <- numeric(nrow(tr))
      for (f in 1:5) { a <- folds != f; b <- folds == f
        z[b] <- if (isTRUE(L$glmnet)) L$fit(Xtr[a, ], ytr[a], par, foldid = as.integer(factor(folds[a])))(Xtr[b, , drop = FALSE])
                else L$fit(Xtr[a, ], ytr[a], par)(Xtr[b, , drop = FALSE]) }
      z })
    loss <- sapply(cvp, function(z) if (isTRUE(L$score)) -w_auc(ytr, z, rep(1, length(z))) else if (clf) logloss(ytr, z) else mean((ytr - z)^2))
    j <- which.min(loss); par <- L$grid[[j]]; z <- cvp[[j]]
    f_all <- if (isTRUE(L$glmnet)) L$fit(Xtr, ytr, par, foldid = folds) else L$fit(Xtr, ytr, par)
    if (isTRUE(L$score)) {                          # SVM: Platt scaling from the out-of-fold scores
      pl <- glm(y ~ s, binomial, data.frame(y = ytr, s = z)); f0 <- f_all
      f_all <- function(Z) as.numeric(predict(pl, data.frame(s = f0(Z)), type = "response"))
      z <- as.numeric(predict(pl, type = "response"))
    }
    if (clf) z <- pmin(pmax(z, 0), 1)
    fits[[k]] <- f_all; oof[[k]] <- z; ins[[k]] <- f_all(Xtr); oos[[k]] <- f_all(Xte)
    secs <- round(as.numeric(difftime(Sys.time(), t1, units = "secs")), 1)
    info <- rbind(info, data.frame(learner = nm(k), settings = paste(names(par), unlist(par), sep = "=", collapse = ", "), seconds = secs))
    cat(sprintf("  %-14s %6.1fs  %s\n", nm(k), secs, info$settings[nrow(info)]))
  }
  Z <- do.call(cbind, oof); wts <- setNames(nnls1(Z, ytr), names(lib))
  ins$Stack <- do.call(cbind, ins[names(lib)]) %*% wts |> as.numeric()
  oos$Stack <- do.call(cbind, oos[names(lib)]) %*% wts |> as.numeric()
  oof$Stack <- as.numeric(Z %*% wts)
  keys <- c(names(lib), "Stack")
  mname <- if (clf) "AUC" else "R2"; mfun <- if (clf) w_auc else w_r2
  P <- do.call(cbind, oos[keys]); boot <- hh_boot(yte, P, wte, te$household, mfun)
  met <- data.frame(scenario = sid, learner = sapply(keys, nm), stack_weight = c(wts, NA),
                    test = sapply(keys, function(k) mfun(yte, oos[[k]], wte)),
                    lo = apply(boot, 2, quantile, 0.025), hi = apply(boot, 2, quantile, 0.975),
                    train = sapply(keys, function(k) mfun(ytr, ins[[k]], wtr)),
                    cv = sapply(keys, function(k) mfun(ytr, oof[[k]], wtr)))
  met$diff_vs_baseline <- met$test - met$test[1]
  met$diff_lo <- apply(boot - boot[, 1], 2, quantile, 0.025); met$diff_hi <- apply(boot - boot[, 1], 2, quantile, 0.975)
  met <- merge(met, info, by = "learner", all.x = TRUE, sort = FALSE)
  met <- met[match(sapply(keys, nm), met$learner), ]
  names(met)[names(met) %in% c("test", "train", "cv")] <- paste0(c("test_", "train_", "cv_"), mname)
  write.csv(met, file.path(out, paste0(sid, "_metrics_R.csv")), row.names = FALSE)
  print(within(met, settings <- NULL), digits = 3, row.names = FALSE)
  best <- keys[which.max(met[[paste0("test_", mname)]])]
  best1 <- names(lib)[which.max(met[[paste0("test_", mname)]][seq_along(lib)])]
  cat("  best on the test set:", nm(best), "; best single learner:", nm(best1), "\n")

  ttl <- setNames(ifelse(keys == "Stack", "Stack", sprintf("%s (weight = %.2f)", sapply(keys, nm), c(wts, 0))), keys)
  sv <- function(p, f, w, h, public) { ggsave(file.path(out, f), p, width = w, height = h, dpi = 200, bg = "white")
    if (public) file.copy(file.path(out, f), file.path(docs, f), overwrite = TRUE) }
  if (!clf) {
    for (tag in c("in_sample", "out_of_sample")) {
      yy <- if (tag == "in_sample") ytr else yte; PP <- if (tag == "in_sample") ins else oos
      g <- do.call(rbind, lapply(keys, function(k) data.frame(panel = ttl[[k]], obs = yy, pred = PP[[k]])))
      g$panel <- factor(g$panel, ttl)
      lim <- quantile(yy, c(0.002, 0.998)) + c(-1, 1) * 0.03 * diff(quantile(yy, c(0.002, 0.998)))
      p <- ggplot(g, aes(obs, pred)) + geom_point(size = 0.4, alpha = 0.25, colour = BLUE) +
        geom_abline(colour = INK) + facet_wrap(~ panel, ncol = 4) + coord_equal(xlim = lim, ylim = lim) +
        labs(x = paste("Observed", S$unit), y = paste("Predicted", S$unit),
             title = paste0(S$title, "\n", if (tag == "in_sample") "In-sample (training data)" else "Out-of-sample (test data)",
                            " predictions; the line is predicted = observed"))
      sv(p, sprintf("fig13_%s_%s_R.png", sid, tag), 11, 9, FALSE)
    }
  } else {
    for (tag in c("in_sample", "out_of_sample")) {
      yy <- if (tag == "in_sample") ytr else yte; PP <- if (tag == "in_sample") ins else oos; ww <- if (tag == "in_sample") wtr else wte
      g <- do.call(rbind, lapply(keys, function(k) cbind(panel = sprintf("%s\nAUC = %.3f", ttl[[k]], w_auc(yy, PP[[k]], ww)), w_roc(yy, PP[[k]], ww))))
      g$panel <- factor(g$panel, unique(g$panel))
      p <- ggplot(g, aes(fpr, tpr)) + geom_abline(colour = GRAY) + geom_step(colour = BLUE, linewidth = 0.6) +
        facet_wrap(~ panel, ncol = 4) + coord_equal() +
        labs(x = "False-positive rate", y = "True-positive rate",
             title = paste0(S$title, "\n", if (tag == "in_sample") "In-sample (training data)" else "Out-of-sample (test data)",
                            " ROC curves, survey-weighted"))
      sv(p, sprintf("fig13_%s_%s_R.png", sid, tag), 11, 9.5, TRUE)
    }
    g <- do.call(rbind, lapply(keys, function(k) { p <- pmin(pmax(oos[[k]], 0), 1); q <- cut(rank(p, ties.method = "first"), 10, labels = FALSE)
      data.frame(panel = sprintf("%s\nBrier = %.3f", ttl[[k]], w_brier(yte, p, wte)),
                 pred = tapply(p * wte, q, sum) / tapply(wte, q, sum), obs = tapply(yte * wte, q, sum) / tapply(wte, q, sum)) }))
    g$panel <- factor(g$panel, unique(g$panel))
    p <- ggplot(g, aes(pred, obs)) + geom_abline(colour = GRAY) + geom_line(colour = BLUE) + geom_point(colour = BLUE, size = 1.2) +
      facet_wrap(~ panel, ncol = 4) + coord_equal(xlim = c(0, 1), ylim = c(0, 1)) +
      labs(x = "Mean predicted probability (decile)", y = "Observed share",
           title = paste0(S$title, "\nCalibration in the test data: deciles of predicted probability, survey-weighted"))
    sv(p, sprintf("fig13_%s_calibration_R.png", sid), 11, 9.5, TRUE)
  }
  m <- met; m$learner <- factor(m$learner, rev(m$learner))
  p <- ggplot(m, aes(y = learner)) + geom_errorbar(aes(xmin = lo, xmax = hi), width = 0, orientation = "y", colour = BLUE, linewidth = 0.9) +
    geom_point(aes(x = .data[[paste0("test_", mname)]], shape = "Test data (95% household-bootstrap interval)"), colour = BLUE, size = 2.6) +
    geom_point(aes(x = .data[[paste0("cv_", mname)]], shape = "Cross-validated (out-of-fold, training data)"), colour = AQUA, size = 2) +
    geom_point(aes(x = .data[[paste0("train_", mname)]], shape = "In-sample (training data)"), colour = ORANGE, size = 2.6, stroke = 1) +
    scale_shape_manual(NULL, values = c(1, 18, 16)) +
    labs(x = paste("Survey-weighted", mname), y = NULL, title = paste0(S$title, "\n", mname, " by learner: in-sample, cross-validated and test")) +
    theme(legend.position = "bottom", legend.direction = "vertical")
  sv(p, sprintf("fig13_%s_metrics_R.png", sid), 6.5, 5, TRUE)

  # permutation importance (survey-weighted rise in squared error / Brier score), variables shuffled whole
  perm <- function(k_set, a) {
    f <- function(dd) { X <- enc(dd); as.numeric(do.call(cbind, lapply(k_set, function(k) fits[[k]](X))) %*% a) }
    base <- wmean((yte - f(te))^2, wte)
    v <- sapply(cols, function(c) mean(replicate(5, { dd <- te; dd[[c]] <- sample(dd[[c]]); wmean((yte - f(dd))^2, wte) - base })))
    data.frame(variable = cols, increase = v, proportion = pmax(v, 0) / sum(pmax(v, 0)))
  }
  vip <- if (best == "Stack") rbind(cbind(model = "Stack", perm(names(lib), wts)), cbind(model = nm(best1), perm(best1, 1)))
         else cbind(model = nm(best), perm(best, 1))
  vip <- vip[order(vip$model, -vip$proportion), ]
  write.csv(vip, file.path(out, paste0(sid, "_importance_R.csv")), row.names = FALSE)
  pl <- lapply(unique(vip$model), function(mo) { v <- head(vip[vip$model == mo, ], 15); v$variable <- factor(v$variable, rev(v$variable))
    ggplot(v, aes(proportion, variable)) + geom_col(fill = BLUE, width = 0.7) + labs(x = "Proportion importance", y = NULL, title = paste0(mo, ": top 15 variables")) })
  p <- wrap_plots(pl, nrow = 1) + plot_annotation(title = paste0(S$title, "\nPermutation importance on the test data (share of the total rise in ",
                                                                if (clf) "Brier score)" else "squared error)"))
  sv(p, sprintf("fig13_%s_vip_R.png", sid), 5.2 * length(pl), 5, TRUE)

  if (sid == "S4") {
    a <- te$white_nh; rate <- wmean(ytr, wtr)
    thr_of <- function(p) { o <- order(-p); p[o][which(cumsum(wtr[o]) / sum(wtr) >= rate)[1]] }
    fm <- function(label, ptr, pte) { t <- thr_of(ptr); yh <- as.numeric(pte >= t)
      g <- function(G) list(sel = wmean(yh[a == G], wte[a == G]), tpr = wmean(yh[a == G & yte == 1], wte[a == G & yte == 1]),
                            fpr = wmean(yh[a == G & yte == 0], wte[a == G & yte == 0]))
      p1 <- g(1); p0 <- g(0)
      data.frame(model = label, AUC = w_auc(yte, pte, wte), disparate_impact = p0$sel / p1$sel, statistical_parity_diff = p0$sel - p1$sel,
                 equal_opportunity_diff = p0$tpr - p1$tpr, average_odds_diff = 0.5 * ((p0$tpr - p1$tpr) + (p0$fpr - p1$fpr))) }
    pa <- mean(tr$white_nh); py <- mean(ytr)
    rw <- ifelse(tr$white_nh == 1, pa, 1 - pa) * ifelse(ytr == 1, py, 1 - py) /
      ave(rep(1, nrow(tr)), tr$white_nh, ytr, FUN = function(x) length(x) / nrow(tr))
    keep <- !grepl("=", colnames(Xtr)) | duplicated(sub("=.*", "", colnames(Xtr))); keep <- keep & apply(Xtr, 2, sd) > 0
    lr_w <- suppressWarnings(glm(y ~ ., quasibinomial, data.frame(y = ytr, Xtr[, keep]), weights = rw))
    xg <- lib$XGBoost$fit(Xtr, ytr, list(n = 500, depth = 2), w = rw)
    fr <- rbind(fm("Logistic", ins$OLS, oos$OLS), fm("XGBoost", ins$XGBoost, oos$XGBoost),
                fm("Logistic + reweighing", predict(lr_w, data.frame(Xtr[, keep]), type = "response"), predict(lr_w, data.frame(Xte[, keep]), type = "response")),
                fm("XGBoost + reweighing", xg(Xtr), xg(Xte)))
    write.csv(fr, file.path(out, "S4_fairness_R.csv"), row.names = FALSE); print(fr, digits = 3, row.names = FALSE)
  }
  cat(sprintf("  %s done in %.1f min\n", sid, as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  met
}

args <- commandArgs(trailingOnly = TRUE); todo <- if (length(args)) args else names(SCEN)
invisible(lapply(todo, run))
# one file across scenarios, rebuilt from the per-scenario files (R2 and AUC columns side by side)
fs <- list.files(out, "^S[0-9b]+_metrics_R\\.csv$", full.names = TRUE)
res <- dplyr::bind_rows(lapply(fs, read.csv))
write.csv(res, file.path(out, "all_metrics_R.csv"), row.names = FALSE)
