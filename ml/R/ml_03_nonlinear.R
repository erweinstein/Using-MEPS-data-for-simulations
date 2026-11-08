# ml_03_nonlinear.R -- Moving beyond linearity: generalized additive models with smoothing
# splines (ISLR ch. 7; ESL ch. 5 and sec. 9.1) and k-nearest neighbours (ISLR sec. 2.2, 3.5, 4.7;
# ESL ch. 13).
#
# GAMs: mgcv's penalized regression splines for the continuous predictors (age, BMI, the SAQ
# scores, and 2022 use and spending on the log scale), linear terms for the rest; smoothness
# chosen by REML. KNN: on standardized predictors, k chosen by the household folds.
# Output: output/ml/results_R.csv (chapter "03 nonlinear"), output/ml/gam_smooths_R.csv
# (the fitted smooth for 2022 spending, for the figure).
#
# Eliot R. Weinstein
# eliotw@uchicago.edu
# erweinstein.com

source("ml/R/ml_common.R")
suppressMessages({library(mgcv); library(FNN)})
ch <- "03 nonlinear"
smooth_vars <- c("age", "bmi", "pcs", "mcs", "log_cost_2022", "log_rx_2022", "log_ob_visits_2022")
lin_vars <- setdiff(predictors_log, smooth_vars)
f_gam <- function(y) as.formula(paste(y, "~", paste(c(sprintf("s(%s, k = 8)", smooth_vars), lin_vars), collapse = " + ")))
res <- list()

gam_fit <- function(y, family) bam(f_gam(y), data = train, family = family, method = "fREML", discrete = TRUE)
g_log <- gam_fit("log_cost", gaussian())
res[[length(res) + 1]] <- evaluate("log_cost", predict(g_log, test), "GAM (splines)", ch)
g_cost <- gam_fit("cost", tw(link = "log"))                  # Tweedie: a point mass at 0 plus a gamma-like tail
res[[length(res) + 1]] <- evaluate("cost", predict(g_cost, test, type = "response"), "GAM, Tweedie (log link)", ch)
for (y in c("high_cost", "any_er", "any_ip")) {
  g <- gam_fit(y, binomial())
  res[[length(res) + 1]] <- evaluate(y, predict(g, test, type = "response"), "GAM (splines)", ch)
}
g_ob <- gam_fit("ob_visits", nb())
res[[length(res) + 1]] <- evaluate("ob_visits", predict(g_ob, test, type = "response"), "GAM, negative binomial", ch)
cat("Tweedie power estimated for spending:", round(g_cost$family$getTheta(TRUE), 3), "\n")
cat("Effective degrees of freedom of the smooths (high_cost GAM):\n"); print(round(summary(g)$edf, 2))

# the fitted smooth of 2022 spending on log-odds of being a top-10% spender in 2023
g_hc <- gam_fit("high_cost", binomial())
nd <- train[rep(1, 100), ]; nd$log_cost_2022 <- seq(0, log1p(2e5), length.out = 100)
sm <- predict(g_hc, nd, type = "terms", se.fit = TRUE)
j <- grep("log_cost_2022", colnames(sm$fit))
write.csv(data.frame(cost_2022 = expm1(nd$log_cost_2022), fit = sm$fit[, j], se = sm$se.fit[, j]),
          file.path(out_dir, "gam_smooths_R.csv"), row.names = FALSE)

# ---- k-nearest neighbours ---------------------------------------------------------------------------
Xtr <- x_matrix(train); Xte <- x_matrix(test); sc <- scaler(Xtr); Ztr <- sc(Xtr); Zte <- sc(Xte)
knn_cv <- function(y, ks = c(5, 10, 20, 40, 80, 160)) {
  err <- sapply(ks, function(k) mean(sapply(1:5, function(f) {
    tr <- train$fold != f
    p <- knn.reg(Ztr[tr, ], Ztr[!tr, ], train[[y]][tr], k = k)$pred
    mean((train[[y]][!tr] - p)^2)
  })))
  ks[which.min(err)]
}
for (y in c("log_cost", "cost", "high_cost", "any_er", "any_ip", "ob_visits")) {
  k <- knn_cv(y)
  p <- knn.reg(Ztr, Zte, train[[y]], k = k)$pred
  res[[length(res) + 1]] <- evaluate(y, p, paste0("KNN (k chosen by CV)"), ch)
  cat(y, ": k =", k, "\n")
}
res <- do.call(rbind, res); log_results(res); show(res)
